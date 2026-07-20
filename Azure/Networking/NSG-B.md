# Network Security Groups — Hotfix Runbook (Mode B: Ops)
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
# 1. What NSGs are actually in play for this NIC/VM? (subnet-level AND NIC-level both matter)
$nic = Get-AzNetworkInterface -ResourceGroupName <rg> -Name <nicName>
$nic.NetworkSecurityGroup.Id                                    # NIC-level NSG (if any)
(Get-AzVirtualNetworkSubnetConfig -ResourceGroupName <rg> -VirtualNetworkName <vnetName> -Name <subnetName>).NetworkSecurityGroup.Id   # subnet-level NSG (if any)

# 2. Effective security rules — the combined, already-merged view. Start here, not with raw rule lists.
az network nic list-effective-nsg --resource-group <rg> --name <nicName> -o table

# 3. Synthetic packet test — does Azure allow or deny this exact 5-tuple, and which rule decided it?
az network watcher test-ip-flow --direction Inbound --protocol TCP `
  --local <vmPrivateIp>:<port> --remote <sourceIp>:* `
  --vm <vmResourceId> --nic <nicName>

# 4. List all custom rules on a specific NSG sorted by priority (lowest number = evaluated first)
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> |
  Select -ExpandProperty SecurityRules | Sort Priority | Format-Table Name,Priority,Direction,Access,SourceAddressPrefix,DestinationPortRange

# 5. Confirm this isn't actually a Security Admin Rule (Azure Virtual Network Manager) — these are evaluated
#    BEFORE any NSG rule and are invisible from Get-AzNetworkSecurityGroup entirely
Get-AzNetworkManager | Get-AzNetworkManagerSecurityAdminConfiguration
```

| If... | Then... |
|---|---|
| Effective rules (step 2) show a `Deny` from a rule you didn't expect | Skip straight to [Fix 1 — Priority conflict](#fix-1) |
| IP flow verify (step 3) says `Denied` by a rule named `DefaultRule_DenyAllInBound`/`DenyAllOutBound` | No explicit allow rule exists yet at any layer — [Fix 4](#fix-4) |
| NIC-level NSG is empty/null but subnet-level NSG exists (or vice versa) | Only one layer is in play — check that layer's rules directly, not both |
| Both a NIC-level and subnet-level NSG exist and effective rules differ from what you expect on one of them | [Fix 2 — Subnet/NIC dual-NSG conflict](#fix-2) |
| Rule references a service tag (`VirtualNetwork`, `Internet`, `AzureCloud`, etc.) and traffic from a peered VNet or on-prem site is unexpectedly blocked | [Fix 3 — Service tag misunderstanding](#fix-3) |
| Rule references an Application Security Group (ASG) and traffic still isn't allowed | [Fix 5 — ASG misconfiguration](#fix-5) |
| A Security Admin Rule exists (step 5) with action `AlwaysAllow` or `Deny` | Traffic never reaches NSG evaluation at all — this is an AVNM problem, not an NSG problem. Escalate to whoever owns the Network Manager configuration. |
| Traffic was working, then suddenly stopped after a recent change | Check `az monitor activity-log list --resource-id <nsgId> --offset 24h` for the change, don't guess |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Security Admin Rules (Azure Virtual Network Manager)
    │  ← evaluated FIRST, before any NSG. "AlwaysAllow"/"Deny" terminate here — NSG never sees the packet.
    │  ← "Allow" (not AlwaysAllow) passes through to NSG evaluation below.
    ▼
Inbound path                              Outbound path
─────────────                              ─────────────
Subnet-level NSG                          NIC-level NSG
    │  ← evaluated first for inbound          │  ← evaluated first for outbound
    ▼                                          ▼
NIC-level NSG                             Subnet-level NSG
    │  ← BOTH must allow, not just one         │  ← BOTH must allow, not just one
    ▼                                          ▼
Within each NSG: rules evaluated lowest-priority-number-first, first match wins, evaluation STOPS
    │
    ▼
Default rules (always present, cannot be deleted, always lowest priority / highest number):
  AllowVNetInBound (65000) / AllowAzureLoadBalancerInBound (65001) / DenyAllInBound (65500)
  AllowVNetOutBound (65000) / AllowInternetOutBound (65001) / DenyAllOutBound (65500)
    │
    ▼
Packet reaches (or is dropped before reaching) the VM/resource
```

**Two independent NSGs must both say yes.** This is the single most common source of "I added an allow rule and it's still blocked" tickets — the engineer added the rule to only one of the two applicable NSGs.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which NSGs apply.**
   ```powershell
   $nic.NetworkSecurityGroup.Id   # null if no NIC-level NSG
   ```
   Expected: either a subnet-level NSG, a NIC-level NSG, both, or neither. If neither, an NSG isn't your problem — look at UDR/route tables or the OS firewall instead.

2. **Pull effective security rules, not raw rule lists.**
   ```
   az network nic list-effective-nsg --resource-group <rg> --name <nicName> -o table
   ```
   This is the pre-merged view Azure actually evaluates — it already accounts for both layers and the default rules. If your custom rule doesn't appear here at all, it was overridden by a higher-priority rule before evaluation ever reached it.

3. **Run IP flow verify with the exact failing 5-tuple.**
   Bad output looks like: `DENY DefaultRule_DenyAllInBound` (no custom rule matched — you need an explicit allow) or `DENY <YourRuleName>` (your own rule is the culprit — check its priority and scope). Good output: `ALLOW <RuleName>`.

4. **If IP flow verify says Allowed but the application still fails**, the NSG isn't your problem. Move to OS-level firewall (Windows Firewall/`iptables`), the application's own bind address, or a route-table (UDR) issue that's sending traffic somewhere else entirely before it ever reaches this NIC.

5. **Check for a Security Admin Rule (AVNM) silently overriding everything.**
   ```powershell
   Get-AzNetworkManager | Get-AzNetworkManagerSecurityAdminConfiguration
   ```
   If this returns configurations with rules targeting the affected VNet, the NSG rules you're staring at may be completely irrelevant — an `AlwaysAllow` or `Deny` admin rule short-circuits NSG evaluation entirely. This is invisible from the NSG blade in the portal and from `Get-AzNetworkSecurityGroup` — it's a genuinely easy miss.

6. **For intermittent/hard-to-reproduce blocks**, use VNet flow logs (not NSG flow logs — see Learning Pointers) with Traffic Analytics to see the actual denied-flow pattern over time rather than a single point-in-time test.

---
## Common Fix Paths

<details><summary id="fix-1">Fix 1 — Priority conflict (deny rule outranks your allow rule)</summary>

**Symptom:** You created an allow rule but traffic is still blocked, and effective security rules show a deny rule with a *lower* priority number (= higher precedence) matching the same traffic.

```powershell
# List all rules sorted by priority to spot the conflict visually
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> |
  Select -ExpandProperty SecurityRules | Sort Priority | Format-Table Name,Priority,Access,Direction,SourceAddressPrefix,DestinationPortRange

# Option A: lower your allow rule's priority number so it's evaluated before the conflicting deny
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName>
Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name <yourAllowRuleName> -Priority 400
$nsg | Set-AzNetworkSecurityGroup

# Option B: narrow the scope of the conflicting deny rule instead of moving your allow rule
# (safer when the deny rule is intentionally broad and other traffic depends on it)
```

**Rollback:** Priority and scope changes are non-destructive and instantly reversible — re-run with the original values. No data loss risk. Existing established connections are unaffected either way (NSG rule changes only apply to new connection attempts).

</details>

<details><summary id="fix-2">Fix 2 — Subnet/NIC dual-NSG conflict</summary>

**Symptom:** Effective security rules show the traffic is allowed by one NSG but the *other* applicable NSG (subnet or NIC) has no matching allow rule, so it falls through to that layer's `DenyAllInBound`.

```powershell
# Confirm both NSGs independently
az network nic list-effective-nsg --resource-group <rg> --name <nicName> -o json |
  ConvertFrom-Json | Select -ExpandProperty value | Select networkSecurityGroup, effectiveSecurityRules

# Add the matching allow rule to whichever NSG is missing it
Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "Allow-<purpose>" `
  -Priority 400 -Direction Inbound -Access Allow -Protocol Tcp `
  -SourceAddressPrefix <source> -SourcePortRange * `
  -DestinationAddressPrefix * -DestinationPortRange <port>
$nsg | Set-AzNetworkSecurityGroup
```

**Simpler long-term fix:** if you don't have a genuine business reason for two independent NSG layers on this NIC, remove one (usually the NIC-level one, keeping policy centralized at the subnet) to eliminate this entire class of ticket going forward. Confirm with the resource owner before removing — some environments intentionally use per-VM NIC NSGs for defense-in-depth.

**Rollback:** Removing a rule/NSG association is reversible by re-adding it. Before removing an NSG association, note its resource ID so it can be re-attached if something unexpected breaks.

</details>

<details><summary id="fix-3">Fix 3 — Service tag misunderstanding</summary>

**Symptom:** A rule uses a service tag and doesn't behave as expected — most commonly, `VirtualNetwork` is assumed to mean "only my local VNet" (it doesn't), or `Internet` is used when the source is actually another Azure VNet.

| Tag | Actually includes |
|---|---|
| `VirtualNetwork` | The VNet's own address space **plus** all peered VNets, all on-premises address spaces connected via VPN Gateway/ExpressRoute, the VNet gateway's own virtual IP, and address prefixes referenced by UDRs. Not just "this VNet." |
| `Internet` | Everything outside the VNet address space reachable via the public internet — including other customers' Azure public IPs. Never use this to mean "another Azure resource." |
| `AzureLoadBalancer` | Only the Azure infrastructure load balancer's own probe/health-check IP. |
| `AzureCloud` | All Azure datacenter public IP ranges tenant-wide — very broad, rarely what you actually want. |

```powershell
# Fix: replace the wrong tag with the correct one
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName>
Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name <ruleName> -SourceAddressPrefix "VirtualNetwork"
$nsg | Set-AzNetworkSecurityGroup
```

**Rollback:** Non-destructive, re-run with the original tag value.

</details>

<details><summary id="fix-4">Fix 4 — Default DenyAll blocking traffic (no explicit allow rule exists anywhere)</summary>

**Symptom:** IP flow verify shows `DENY` by `DefaultRule_DenyAllInBound` (priority 65500) or `DefaultRule_DenyAllOutBound` — no custom rule matched at all.

```powershell
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName>
Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name "Allow-<purpose>" `
  -Priority 400 -Direction Inbound -Access Allow -Protocol Tcp `
  -SourceAddressPrefix <source> -SourcePortRange * `
  -DestinationAddressPrefix * -DestinationPortRange <port>
$nsg | Set-AzNetworkSecurityGroup
```

Common ports for reference: RDP `3389`, SSH `22`, HTTP `80`, HTTPS `443`.

**Better long-term fix for management ports (RDP/SSH):** don't open these permanently at all — use Azure Bastion (see `Bastion-A.md`/`Bastion-B.md`) or Defender for Cloud Just-In-Time (JIT) VM access instead, which opens the port only for a limited window with an audit trail. Flag this to the client if you find a permanently-open 3389/22 rule during triage.

**Rollback:** Remove the rule; non-destructive to existing connections until removed (existing sessions stay up per Azure's stateful flow-record behavior, only new connection attempts are affected).

</details>

<details><summary id="fix-5">Fix 5 — Application Security Group (ASG) misconfiguration</summary>

**Symptom:** A rule references an ASG and traffic still isn't allowed, or the rule can't even be saved.

```powershell
# Check ASG membership — is the VM's NIC actually in the ASG the rule references?
$nic = Get-AzNetworkInterface -ResourceGroupName <rg> -Name <nicName>
$nic.IpConfigurations[0].ApplicationSecurityGroups

# Confirm the ASG and the NSG referencing it are in the SAME virtual network — this is a hard requirement
Get-AzApplicationSecurityGroup -ResourceGroupName <rg> -Name <asgName> | Select Location, Id
```

Three known failure patterns, in order of frequency:
1. **VM's NIC was never added to the ASG.** Add it via the NIC's Networking blade → Application Security Groups, or `$nic.IpConfigurations[0].ApplicationSecurityGroups.Add(...)` then `Set-AzNetworkInterface`.
2. **ASG and NSG live in different VNets.** An NSG rule can only reference an ASG whose member NICs are in the same VNet as the NSG. Recreate the rule using explicit IP ranges instead, or move the resources.
3. **Rule tries to mix an ASG with a raw IP range in the same source/destination field.** Not supported — split into two separate rules, one ASG-based and one IP-based.

**Rollback:** ASG membership and rule changes are non-destructive and reversible.

</details>

---
## Escalation Evidence

Copy this template and fill in before escalating — this is what a network engineer needs to pick the ticket up cold:

```
NSG ESCALATION — <date/time>
Affected resource: <VM/resource name and resource ID>
NIC: <nic name>          Subnet: <subnet name>          VNet: <vnet name>
NSG(s) in play: subnet-level = <name or "none"> | NIC-level = <name or "none">

Failing traffic:
  Direction: <Inbound/Outbound>   Protocol: <TCP/UDP>
  Source: <ip/CIDR/tag>   Source port: <port or *>
  Destination: <ip>   Destination port: <port>

Effective security rules output (attach or paste):
  az network nic list-effective-nsg --resource-group <rg> --name <nicName> -o json

IP flow verify result:
  Result: <Allow/Deny>   Rule that decided it: <ruleName>

Security Admin Rules checked?  <Yes — none found / Yes — found: <details> / No>

Recent changes (last 24h, from activity log):
  <paste az monitor activity-log output or "none found">

What's been tried:
  <bullet list>

Business impact / urgency:
  <one line>
```

---
## 🎓 Learning Pointers

- **NSG flow logs are being retired (September 30, 2027) and can no longer be newly created (cutoff was June 30, 2025 — already past).** Any client still asking to "turn on NSG flow logs" needs to be redirected to VNet flow logs instead — see [VNet flow logs overview](https://learn.microsoft.com/en-us/azure/network-watcher/vnet-flow-logs-overview) and the [migration guide](https://learn.microsoft.com/en-us/azure/network-watcher/nsg-flow-logs-migrate). VNet flow logs capture traffic at the VNet/subnet level and catch flows to NICs that have no NSG attached at all — something NSG flow logs structurally can't see.
- **Two independent NSGs both have to say yes — this is the #1 real-world root cause behind this whole topic.** Get in the habit of checking `list-effective-nsg` before touching individual rule lists; it saves the "I fixed the subnet NSG but forgot the NIC NSG" round-trip.
- **`VirtualNetwork` the service tag is not "my VNet only."** It silently includes peered VNets, on-prem sites connected via gateway, and UDR-referenced prefixes. A rule using this tag is broader than most engineers assume on first read.
- **Security Admin Rules from Azure Virtual Network Manager are invisible from the NSG blade and from `Get-AzNetworkSecurityGroup`.** If NSG rules look completely correct and traffic is still blocked (or unexpectedly allowed), check for an AVNM security admin configuration before spending more time on the NSG itself — see [Security admin rules concept](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-security-admins).
- **Existing connections survive a rule change; only new connections are affected.** Don't assume a live RDP/SSH session dropping is an NSG problem — NSGs don't tear down established sessions when a rule is removed.
- For fleet-wide review of overly permissive rules (broad `Internet`/`Any` sources on management ports), use Microsoft Defender for Cloud's NSG recommendations rather than a manual per-rule review — see [Microsoft Community Hub: VNet flow logs migration guide](https://techcommunity.microsoft.com/blog/azureinfrastructureblog/azure-vnet-flow-logs-with-terraform-the-complete-migration-and-traffic-analytics/4468225) for a Traffic-Analytics-driven approach to spotting these at scale.
