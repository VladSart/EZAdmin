# Network Security Groups — Reference Runbook (Mode A: Deep Dive)
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

Covers Azure Network Security Groups (NSGs) as a **general-purpose design and troubleshooting topic**: rule evaluation order, the subnet-vs-NIC dual-application model, service tags, Application Security Groups (ASGs), augmented security rules, Security Admin Rules (Azure Virtual Network Manager), and flow-log-based diagnostics. This is the shared data-plane layer that sits underneath every other Azure networking topic in this repo — `Azure/Networking/HybridConnectivity-A.md` (VPN Gateway/ExpressRoute), `Azure/AVD/AVD-Connectivity-A.md` (AVD session host reachability), and `Azure/Windows365/Windows365-A.md` (Cloud PC network requirements) all converge on NSG evaluation as their final data-plane checkpoint, but this runbook is where the NSG mechanics themselves are documented in full so those other files don't have to repeat it.

Does **not** cover: Azure Firewall or third-party NVA (network virtual appliance) policy — a different, stateful, centrally-managed filtering layer that sits at the hub in a hub-and-spoke or Virtual WAN topology, evaluated independently of NSGs; User-Defined Routes (UDR)/route tables — a routing-layer concept, not a filtering-layer one, though the two are frequently confused ("traffic is going the wrong place" is a UDR problem, "traffic is being blocked" is an NSG problem); or Web Application Firewall (WAF) / Application Gateway rules, which operate at Layer 7 on HTTP(S) traffic specifically.

---
## How It Works

<details><summary>Full architecture</summary>

**The five-tuple.** Every NSG rule is evaluated against source address, source port, destination address, destination port, and protocol. A rule matches only if all five align with the traffic in question.

**Two independent application points.** An NSG can be associated with a **subnet** (applies to every NIC in that subnet) and/or a **NIC directly** (applies to that one network interface only). Both can be in play simultaneously for the same VM, and — this is the load-bearing fact of this entire topic — **both must independently allow the traffic** for it to succeed. Azure evaluates them in a fixed, direction-dependent order:

- **Inbound traffic:** subnet-level NSG evaluated first, then NIC-level NSG.
- **Outbound traffic:** NIC-level NSG evaluated first, then subnet-level NSG.

A deny at either layer blocks the traffic regardless of what the other layer says. There is no "OR" logic between the two layers — only "AND."

**Rule evaluation within a single NSG.** Rules are evaluated strictly by priority number, lowest first (priority range 100–4096; lower number = higher precedence). The moment a rule matches the five-tuple, evaluation **stops** — no further rules in that NSG are considered, including any that might also have matched with a different action. This is why a broad, low-priority-number deny rule can silently shadow a more specific, higher-priority-number allow rule placed after it; the allow rule is never even reached. Two rules cannot share the same priority and direction — Azure rejects the creation outright.

**Default rules — always present, cannot be deleted.** Every NSG ships with six rules baked in, always at the lowest possible precedence (highest numbers) so custom rules are always evaluated first:

| Priority | Name | Direction | Action |
|---|---|---|---|
| 65000 | AllowVNetInBound | Inbound | Allow |
| 65001 | AllowAzureLoadBalancerInBound | Inbound | Allow |
| 65500 | DenyAllInBound | Inbound | Deny |
| 65000 | AllowVNetOutBound | Outbound | Allow |
| 65001 | AllowInternetOutBound | Outbound | Allow |
| 65500 | DenyAllOutBound | Outbound | Deny |

They can be **overridden** (by adding a custom rule with a lower priority number and opposite action) but never removed. `DenyAllInBound` at 65500 is the reason a brand-new NSG with zero custom rules blocks all unsolicited inbound traffic by default — this is expected behavior, not a misconfiguration, and is the most common "why is nothing working" first-day question.

**Service tags** represent a Microsoft-maintained, dynamically-updated group of IP prefixes for a category of traffic — `VirtualNetwork`, `Internet`, `AzureLoadBalancer`, `AzureCloud`, and dozens more scoped to specific PaaS services (`Storage`, `Sql`, `EventHub`, etc., often region-specific as `Storage.EastUS` etc.). Using a tag means Azure keeps the underlying IP ranges current automatically — no manual rule maintenance when Microsoft's own infrastructure IPs change. The most consequential tag to understand correctly is `VirtualNetwork`: it resolves to the VNet's own address space **plus** all peered VNets, all on-premises address spaces reachable via a connected VPN Gateway or ExpressRoute circuit, the gateway's own virtual IP, and any address prefixes referenced in UDRs — considerably broader than "just this VNet," and a frequent source of both accidental over-permissiveness and accidental under-permissiveness (assuming it does NOT include a peered VNet when in fact it does).

**Application Security Groups (ASGs)** let a rule reference a *logical group of NICs* instead of an IP range — VMs are added to an ASG, and NSG rules reference the ASG by name (e.g., "allow port 1433 from `asg-webtier` to `asg-dbtier`"). This decouples the security policy from IP addressing entirely, which matters a great deal at scale (VM added to a scale set, autoscaled, or re-IP'd — the rule doesn't need to change). Hard constraints: the ASG and the NSG referencing it must exist in the **same virtual network** (an ASG's members and the NSG evaluating them must be co-located), and a single rule cannot mix an ASG reference with a raw IP address/range for the same source or destination field — these have to be separate rules.

**Augmented security rules** allow a single rule to specify multiple explicit IP addresses/ranges and multiple ports/port-ranges (comma-separated) instead of requiring one rule per address/port combination — this reduces rule sprawl but a single service tag or ASG still can't be combined with multiple *other* tags/ASGs in one rule.

**Security Admin Rules (Azure Virtual Network Manager)** are a distinct, higher-precedence enforcement layer that sits entirely outside the NSG resource model. AVNM lets a central network team define rules that apply across subscriptions/VNets via network groups, independent of what any individual subscription owner configures on their own NSGs. These rules are **always evaluated before any NSG rule** and come in three action types with materially different downstream behavior:

- **Allow** — traffic continues on to NSG evaluation as normal (this action type is essentially a "definitely don't block this," not a bypass).
- **AlwaysAllow** — traffic is delivered directly to the destination, **completely bypassing NSG evaluation**, even if an NSG would have denied it.
- **Deny** — traffic is blocked outright, terminating evaluation before any NSG is ever consulted.

This is the single most commonly-missed layer during NSG troubleshooting precisely because it's invisible from the NSG blade in the portal and from `Get-AzNetworkSecurityGroup` — an engineer can stare at perfectly correct NSG rules for an hour without realizing the actual decision was already made one layer up.

**Flow timeout and stateful behavior.** NSGs are stateful — a flow record is created per connection, so an outbound-allowed connection's return traffic doesn't need a matching inbound rule (and vice versa). Removing a rule that was allowing an *established* connection does not tear that connection down; only new connection attempts are affected going forward.

</details>

---
## Dependency Stack

```
Layer 0 — Azure Virtual Network Manager (Security Admin Rules)
          Cross-subscription, centrally enforced, invisible from the NSG resource itself.
          "AlwaysAllow"/"Deny" terminate evaluation here entirely; "Allow" passes through.
              │
              ▼
Layer 1 — Subnet-level NSG (inbound-first) / NIC-level NSG (outbound-first)
          The first of the two per-direction NSG layers Azure evaluates.
              │
              ▼
Layer 2 — The other NSG layer (NIC-level for inbound, subnet-level for outbound)
          BOTH Layer 1 and Layer 2 must allow — this is an AND, not an OR.
              │
              ▼
Layer 3 — Rule evaluation within each NSG: priority order, first match wins, stops immediately
          Custom rules (100-4096) always evaluated before the six built-in default rules (65000-65500).
              │
              ▼
Layer 4 — Rule resolution: service tags / ASGs / augmented multi-IP-multi-port rules
          resolved to their underlying IP/port sets at evaluation time.
              │
              ▼
Layer 5 — Default rules (cannot be deleted, only overridden by a lower-numbered custom rule)
          AllowVNet(In/Out)Bound → AllowAzureLoadBalancerInBound/AllowInternetOutBound → DenyAll(In/Out)Bound
              │
              ▼
Layer 6 — Routing (UDR / effective routes) — a SEPARATE concern from NSG filtering entirely
          An NSG allowing traffic does not guarantee it's routed to the right place, and vice versa.
              │
              ▼
Packet delivered to (or dropped before reaching) the resource
```

Layer 0 and Layer 6 are the two layers engineers most often forget exist when troubleshooting "the NSG rules look right but it's still not working."

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| New NSG, zero custom rules, all inbound traffic blocked | Expected — `DenyAllInBound` (65500) is a default rule, not a misconfiguration | `Get-AzNetworkSecurityGroup` — confirm no custom allow rules exist yet |
| Allow rule added but traffic still blocked | A lower-priority-number deny rule matches the same traffic and is evaluated first | Sort rules by `Priority`, look for a deny above your allow |
| Traffic allowed by one NSG, still blocked overall | The *other* applicable NSG (subnet or NIC) has no matching allow, falls to its own `DenyAllInBound` | `az network nic list-effective-nsg` — compare both layers |
| Rule references `VirtualNetwork` tag; traffic from a peered VNet or on-prem site behaves unexpectedly (either blocked when expected allowed, or allowed when expected blocked) | Misunderstanding of what `VirtualNetwork` actually resolves to (peered VNets + on-prem + gateway VIP + UDR prefixes, not just the local VNet) | Review the tag's actual resolved scope, not its name |
| ASG-based rule doesn't work; rule can't be saved at all | NIC not in the ASG, ASG in a different VNet than the NSG, or ASG mixed with a raw IP in the same field | Check NIC's ASG membership and VNet co-location |
| NSG rules all look correct; traffic still unexpectedly blocked (or allowed) | A Security Admin Rule from Azure Virtual Network Manager is short-circuiting evaluation before the NSG is ever consulted | `Get-AzNetworkManagerSecurityAdminConfiguration` |
| NSG shows Allow via IP flow verify but the application still fails | Not an NSG problem — check OS firewall, application bind address, or UDR routing the traffic elsewhere | `test-ip-flow` result vs. actual observed behavior |
| Two rules with the same priority can't be created | Azure hard constraint — priority + direction must be unique per NSG | Choose a different unused priority number |
| Existing RDP/SSH session dropped after a rule change | Unlikely to be the rule change itself — NSGs are stateful and don't tear down established connections | Check for a different cause (idle timeout, VM restart, host maintenance) |
| "We enabled NSG flow logs" request from a client | No longer possible for new deployments — creation blocked since June 30, 2025, full retirement September 30, 2027 | Redirect to VNet flow logs instead |
| Traffic allowed by NSG but flow-log/Traffic-Analytics dashboard shows nothing | Using legacy NSG flow logs on a NIC/subnet with no NSG attached at all (structurally invisible to NSG flow logs) — or dashboard hasn't caught up (Traffic Analytics has processing latency, not real-time) | Confirm which flow-log type is enabled; consider migrating to VNet flow logs |
| Rule change made, ticket says "still broken" minutes later | NSG rule changes apply to *new* connections only — an already-open client session needs to reconnect to pick up the change | Have the user retry the connection, don't assume the fix failed |

---
## Validation Steps

1. **Confirm which NSGs are actually associated with this NIC/subnet.**
   ```powershell
   $nic.NetworkSecurityGroup.Id
   (Get-AzVirtualNetworkSubnetConfig ...).NetworkSecurityGroup.Id
   ```
   Good: at least one is populated (or you've confirmed NSG isn't relevant to this ticket at all). Bad: assuming a layer exists without checking — a very common wasted-time pattern.

2. **Pull effective security rules — the pre-merged, already-evaluated view.**
   ```
   az network nic list-effective-nsg --resource-group <rg> --name <nicName> -o table
   ```
   Good: your expected allow rule appears in the output with `Allow`. Bad: it's missing entirely (overridden before evaluation reached it) or appears but the NIC still can't communicate (routing/OS-firewall problem instead).

3. **Run IP flow verify with the failing traffic's exact 5-tuple.**
   Good: `Allow` with the rule name you expect. Bad: `Deny` — note which rule name is cited, it tells you exactly where to look next (a default rule name means no custom rule matched at all; a custom rule name means that specific rule is the blocker).

4. **Check for Security Admin Rules from Azure Virtual Network Manager.**
   ```powershell
   Get-AzNetworkManager | Get-AzNetworkManagerSecurityAdminConfiguration
   ```
   Good: none exist, or existing ones don't target this VNet/subscription. Bad: an `AlwaysAllow` or `Deny` configuration targets this resource — NSG rules are not the effective decision-maker here.

5. **If using service tags, confirm the resolved scope matches intent.**
   ```
   Get-AzNetworkServiceTag -Location <region> | Select -ExpandProperty Values | Where {$_.Name -eq "VirtualNetwork"}
   ```
   Good: engineer understands and confirms the actual resolved IP ranges/scope. Bad: assuming the tag name alone describes its full scope.

6. **If using ASGs, confirm membership and VNet co-location.**
   ```powershell
   $nic.IpConfigurations[0].ApplicationSecurityGroups
   ```
   Good: target NIC's ASG list includes the ASG referenced in the rule, and the ASG's location/VNet matches the NSG's. Bad: NIC never added, or cross-VNet mismatch.

7. **Confirm routing isn't the actual problem once NSG allows the traffic.**
   ```
   az network nic show-effective-route-table --resource-group <rg> --name <nicName> -o table
   ```
   Good: the expected next hop for the destination prefix. Bad: traffic is being routed to an NVA/firewall/gateway that then drops it — a UDR problem masquerading as an NSG problem.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Scope the problem.** Is this genuinely an NSG issue, or does it just look like one? Run IP flow verify first — if it says `Allow` and the traffic still fails, stop working the NSG angle and pivot to OS firewall, application config, or UDR.

**Phase 2 — Identify which layer(s) apply.** Subnet-level, NIC-level, both, or (rarely, if intentionally left off) neither. Pull effective security rules rather than reasoning about the two layers separately in your head — the merged view is authoritative.

**Phase 3 — Check for Security Admin Rules before going deeper into NSG rule details.** This is a five-second check that prevents the single most time-wasting failure mode in this entire topic: spending 30 minutes perfecting NSG rules that were never actually the decision-maker.

**Phase 4 — Diagnose the specific NSG-layer cause.** Priority conflict, missing rule at one of the two layers, service tag scope misunderstanding, or ASG membership/co-location issue — use the Symptom → Cause Map above to jump directly to the likely cause rather than reading every rule top to bottom.

**Phase 5 — Validate the fix with IP flow verify again**, using the exact same 5-tuple as the original failure, before telling the client/user it's resolved.

**Phase 6 — Confirm downstream (routing, OS firewall, application) once NSG is confirmed allowing traffic**, if the original symptom hasn't actually cleared.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide NSG hygiene sweep (overly permissive rules)</summary>

For an MSP taking over a new client environment or doing a periodic security review:

1. Run `Scripts/Get-NSGRuleAudit.ps1 -AllNsgs` across the subscription to flag broad `Internet`/`Any` sources on management ports (3389, 22) and any rule with no description/tag indicating business justification.
2. Cross-reference flagged rules against Microsoft Defender for Cloud's own NSG recommendations (`Get-AzSecurityTask` or the Defender for Cloud portal) — Defender already tracks a mature ruleset for "internet-facing NSG allows unrestricted access."
3. For each broad management-port rule, propose either narrowing the source to a known management IP range, or replacing it entirely with Azure Bastion (see `Bastion-A.md`/`Bastion-B.md` for deployment and its own required NSG rule set) / Defender for Cloud Just-In-Time access.
4. Document findings and get client sign-off before making changes — don't silently tighten rules on a live production environment without a change window, since a too-narrow fix can cause an outage as easily as a too-broad rule caused an exposure.

**Rollback:** Keep a pre-change export of every modified NSG (`Get-AzNetworkSecurityGroup | ConvertTo-Json -Depth 10`) so any rule can be restored exactly if the tightening breaks something unexpected.

</details>

<details><summary>Playbook 2 — Migrating from NSG flow logs to VNet flow logs</summary>

Relevant to any client environment still relying on NSG flow logs for Traffic Analytics, given the September 30, 2027 retirement (and the fact new NSG flow logs can no longer be created as of June 30, 2025 — already past as of this writing).

1. Inventory existing NSG flow log configurations: `Get-AzNetworkWatcherFlowLog` across each Network Watcher-enabled region.
2. Enable VNet flow logs at the VNet or subnet level (broader capture scope than NSG flow logs — also catches NICs with no NSG attached) using the same Log Analytics workspace / storage account destination where practical to preserve historical query continuity.
3. Run both in parallel for a transition period so Traffic Analytics dashboards aren't interrupted, then decommission the NSG flow log configuration.
4. Update any saved KQL queries or workbooks that reference the NSG-flow-log-specific schema — VNet flow logs use a distinct (v2) schema; see [Migrate to Virtual Network Flow Logs](https://learn.microsoft.com/en-us/azure/network-watcher/nsg-flow-logs-migrate).

**Rollback:** Non-destructive — both flow log types can run simultaneously during transition, and disabling VNet flow logs doesn't affect NSG flow log data already collected (which continues to follow its own configured retention policy even after the parent feature's retirement date).

</details>

<details><summary>Playbook 3 — Security Admin Rule conflict investigation (AVNM)</summary>

When a client's central network team manages Azure Virtual Network Manager and a subscription owner's NSG changes don't seem to "take":

1. Confirm the VNet is part of a Network Manager network group: `Get-AzNetworkManagerConnection`, `Get-AzNetworkManager`.
2. List security admin configurations and their rule collections: `Get-AzNetworkManagerSecurityAdminConfiguration` → `Get-AzNetworkManagerSecurityAdminRuleCollection` → `Get-AzNetworkManagerSecurityAdminRule`.
3. Identify whether an `AlwaysAllow` or `Deny` rule targets the affected resource — these are the two action types that bypass or override NSG evaluation entirely.
4. If a genuine conflict exists between the central policy and a subscription-level need, escalate to the Network Manager owner rather than attempting to work around it at the NSG level — NSG changes cannot override an `AlwaysAllow`/`Deny` admin rule by design, so time spent adjusting NSG rules in this scenario is wasted effort.

**Rollback:** N/A — this playbook is diagnostic/escalation only, no changes made at the NSG level.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  NSG evidence-pack collector for escalation — single VM/NIC scope.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$NicName,
    [string]$OutputPath = ".\NSG-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss).json"
)

$nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $NicName
$subnetId = $nic.IpConfigurations[0].Subnet.Id
$vnetName = ($subnetId -split '/')[8]
$subnetName = ($subnetId -split '/')[10]

$evidence = [ordered]@{
    CollectedAt      = (Get-Date).ToString("o")
    Nic              = $nic.Name
    NicLevelNsg      = $nic.NetworkSecurityGroup.Id
    SubnetLevelNsg   = (Get-AzVirtualNetworkSubnetConfig -ResourceGroupName $ResourceGroupName -VirtualNetworkName $vnetName -Name $subnetName).NetworkSecurityGroup.Id
    EffectiveRulesRaw = (az network nic list-effective-nsg --resource-group $ResourceGroupName --name $NicName -o json | ConvertFrom-Json)
    SecurityAdminConfigs = @(Get-AzNetworkManager -ErrorAction SilentlyContinue | Get-AzNetworkManagerSecurityAdminConfiguration -ErrorAction SilentlyContinue)
    RecentActivityLog = @(Get-AzLog -ResourceId $nic.Id -StartTime (Get-Date).AddHours(-24) -ErrorAction SilentlyContinue |
        Select EventTimestamp, OperationName, Caller, Status)
}

$evidence | ConvertTo-Json -Depth 10 | Out-File $OutputPath
Write-Host "Evidence pack written to $OutputPath"
```

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| List NIC's own NSG | `$nic.NetworkSecurityGroup.Id` |
| List subnet's NSG | `(Get-AzVirtualNetworkSubnetConfig -ResourceGroupName <rg> -VirtualNetworkName <vnet> -Name <subnet>).NetworkSecurityGroup.Id` |
| Effective security rules (CLI) | `az network nic list-effective-nsg --resource-group <rg> --name <nic> -o table` |
| Effective security rules (PowerShell) | `Get-AzEffectiveNetworkSecurityGroup -NetworkInterfaceName <nic> -ResourceGroupName <rg>` |
| IP flow verify (CLI) | `az network watcher test-ip-flow --direction Inbound --protocol TCP --local <ip>:<port> --remote <ip>:* --vm <vmId> --nic <nic>` |
| IP flow verify (PowerShell) | `Test-AzNetworkWatcherIPFlow -NetworkWatcher $nw -Direction Inbound -Protocol TCP -LocalIPAddress <ip> -LocalPort <port> -RemoteIPAddress <ip> -RemotePort * -TargetVirtualMachineId <vmId>` |
| List NSG rules sorted by priority | `Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsg> \| Select -ExpandProperty SecurityRules \| Sort Priority` |
| Effective route table (routing, not NSG) | `az network nic show-effective-route-table --resource-group <rg> --name <nic> -o table` |
| Connection troubleshoot (full path test) | Portal: Network Watcher → Connection troubleshoot |
| Security Admin configurations | `Get-AzNetworkManager \| Get-AzNetworkManagerSecurityAdminConfiguration` |
| Add an allow rule | `Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name <name> -Priority <n> -Direction Inbound -Access Allow -Protocol Tcp -SourceAddressPrefix <src> -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange <port>` |
| List resolvable service tag IP ranges | `Get-AzNetworkServiceTag -Location <region>` |
| Check NIC's ASG membership | `$nic.IpConfigurations[0].ApplicationSecurityGroups` |
| List all NSGs in a subscription | `Get-AzNetworkSecurityGroup` |
| Recent changes to an NSG | `Get-AzLog -ResourceId <nsgResourceId> -StartTime (Get-Date).AddHours(-24)` |

---
## 🎓 Learning Pointers

- **This topic is the shared foundation underneath every other Azure connectivity runbook in this repo.** Once the "two independent layers, priority-ordered, first-match-wins, Security-Admin-Rules-evaluated-first" model is solid, `HybridConnectivity-A.md`'s Fix 5 (routes look fine but traffic still doesn't reach the destination) and `AVD-Connectivity-A.md`'s NSG/service-tag guidance both become much faster to reason through, since they're applying this same model to a narrower scenario rather than teaching it from scratch.
- **Security Admin Rules (Azure Virtual Network Manager) are the newest and most commonly-missed layer in this entire model.** They didn't exist in Azure's original NSG-only world, and plenty of engineers who learned NSGs years ago have never encountered them. See [Security admin rules concept](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-security-admins) — worth reading end to end once, since the "Allow vs. AlwaysAllow vs. Deny" distinction is easy to misremember under pressure.
- **NSG flow logs' retirement (September 30, 2027, no new creation since June 30, 2025) is a genuinely current platform change** — see the [official retirement announcement](https://azure.microsoft.com/updates/v2/Azure-NSG-flow-logs-Retirement) and the [VNet flow logs overview](https://learn.microsoft.com/en-us/azure/network-watcher/vnet-flow-logs-overview). Any client-facing recommendation involving flow logs should default to VNet flow logs now, not NSG flow logs, even though a lot of existing documentation and community content still references the older feature.
- **`VirtualNetwork` the service tag is broader than its name suggests** — peered VNets, on-prem via gateway, and UDR-referenced prefixes are all included. This single misunderstanding accounts for a disproportionate share of "why is traffic from our other site being blocked/allowed unexpectedly" tickets. See [Virtual network service tags](https://learn.microsoft.com/en-us/azure/virtual-network/service-tags-overview) for the full authoritative list.
- **NSGs are stateful — don't diagnose a dropped live session as an NSG rule change.** Established connections survive rule removal; only new connection attempts are affected. This distinction has sent more than one engineer down the wrong troubleshooting path.
- For a structured walkthrough of the exact diagnostic tooling (IP flow verify, effective security rules, connection troubleshoot) with portal/CLI/PowerShell parity, see Microsoft's own [Troubleshoot NSG misconfigurations that block traffic](https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-network/virtual-network-troubleshoot-nsg-blocking-traffic) support article — this runbook's Diagnosis & Validation Flow is modeled directly on it.
