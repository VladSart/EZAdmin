# Azure Virtual Network Manager — Hotfix Runbook (Mode B: Ops)
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
# 1. Does the Network Manager instance exist, and what's its scope (management group or subscriptions)?
Get-AzNetworkManager -ResourceGroupName <nmRg> -Name <networkManagerName> |
  Select Name, NetworkManagerScope, NetworkManagerScopeAccesses

# 2. Is the VNet actually a member of the network group this configuration targets — and is membership static or dynamic?
Get-AzNetworkManagerGroup -ResourceGroupName <nmRg> -NetworkManagerName <networkManagerName> -Name <groupName> |
  Select Name, MemberType, ConditionalMembership

# 3. THE single highest-value command in this whole topic — what's actually, authoritatively applied to this VNet right now
#    (not what you configured, not what you think should apply — what Azure is actually enforcing)
Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName <vnetName> -VirtualNetworkResourceGroupName <vnetRg>

# 4. Was the configuration ever deployed to this VNet's region? Configurations that exist but were never
#    deployed do nothing — this is the #1 real-world "why isn't this working" root cause per Microsoft's own FAQ.
Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <networkManagerName> `
  -Region @("<vnetRegion>") -DeploymentType @("Connectivity")

# 5. Confirm this isn't a Security Admin Rule problem in disguise (different config type, evaluated before NSGs —
#    fully covered in NSG-A.md/NSG-B.md, not repeated here)
Get-AzNetworkManagerEffectiveSecurityAdminRule -VirtualNetworkName <vnetName> -VirtualNetworkResourceGroupName <vnetRg>
```

| If... | Then... |
|---|---|
| Step 3 returns nothing at all for a VNet you expect to be governed | [Fix 1 — VNet not receiving any configuration](#fix-1) |
| Step 4 shows `DeploymentStatus: Deploying` or no entry for the target region | Configuration was never deployed to that region — [Fix 1](#fix-1) |
| Step 4 shows `DeploymentStatus: Failed` with a populated `ErrorMessage` | Read the error message directly — it's the only place Azure surfaces deployment failure detail — then re-deploy |
| VNet was recently added to a *dynamic* (Azure-Policy-based) network group and isn't showing up yet | [Fix 2 — Dynamic membership hasn't caught up](#fix-2) |
| You modified one connectivity configuration and a *different*, previously-working configuration in the same region stopped applying | [Fix 3 — Goal-state redeploy trap](#fix-3) |
| Hub-and-spoke topology: peering exists from spoke→hub but not hub→spoke (or spokes can't reach the gateway) | [Fix 4 — "Use hub as gateway" silent partial-peering](#fix-4) |
| Two VNets in the same mesh have overlapping address spaces and can't reach each other's overlapping subnets specifically | [Fix 5 — Overlapping address space in a mesh](#fix-5) |
| Effective connectivity config (step 3) looks correct but traffic still fails | Not an AVNM problem — check NSG evaluation (`NSG-B.md`) and UDR/routing next |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Network Manager instance
    │  ← deployed at a management group or subscription SCOPE — this scope is a hard ceiling
    │     ("enough access is delegated to apply configurations to resources within scope,
    │       and only within scope" — a VNet outside scope receives nothing, silently)
    ▼
Network Group membership
    │  ← STATIC: manually added, takes effect immediately
    │  ← DYNAMIC: Azure Policy-based (subscription/tag/resource-group conditions) —
    │     policy evaluation runs ~every 30 min; in environments >1,000 subscriptions,
    │     the notification window can be up to 24 hours before AVNM even sees the new VNet
    ▼
Configuration object exists (connectivity / security admin / routing)
    │  ← creating/saving a configuration does NOTHING by itself — it is inert until deployed
    ▼
Deployment (per-region commit)
    │  ← "goal state" model: deploying Config-A + Config-B to a region makes those two,
    │     and ONLY those two, the enforced state for that region — anything previously
    │     deployed and NOT included in the new deploy request is REMOVED
    ▼
Underlying construct realized
    │  ← Mesh → "connected group" (Azure-native construct, NOT visible in the Peerings blade)
    │  ← Hub-and-spoke w/ hub VNet → real virtual network peering
    │  ← Hub-and-spoke w/ Virtual WAN hub (preview) → VWAN virtual network connection
    ▼
Effective state on the VNet (Get-AzNetworkManagerEffectiveConnectivityConfiguration — the only fully authoritative view)
```

**The scope ceiling and the goal-state redeploy trap are the two most common real-world root causes in this whole topic** — both fail silently with no error, no alert, nothing in the portal that says "this didn't work."

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the VNet is in scope of the network manager, not just in a network group.**
   A network group can list a VNet that's outside the network manager's delegated management-group/subscription scope. Out-of-scope members receive nothing — this is explicitly called out in Microsoft's own troubleshooting FAQ as the second thing to check, right after "was it deployed."

2. **Pull effective connectivity configuration, not the configured intent.**
   ```powershell
   Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName <vnetName> -VirtualNetworkResourceGroupName <vnetRg>
   ```
   Empty result = either never deployed to this region, VNet out of scope, or VNet not actually a network-group member (check membership type/timing next). A populated result showing a configuration you didn't expect = a stale deployment nobody redeployed after a config change.

3. **For mesh topologies specifically, do not look at the Peerings blade.** A mesh (and hub-and-spoke "direct connectivity") is realized as a **connected group**, an AVNM-native construct that never appears as a peering resource. Effective routes on an affected NIC show next-hop type `ConnectedGroup`, not `VNetPeering`. Looking for peerings that will never exist wastes real triage time — this is one of the most common false-negative dead ends in this topic.

4. **Check deployment status per region, per configuration type.**
   ```powershell
   Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Region @("<region>") -DeploymentType @("Connectivity")
   ```
   Good: `DeploymentStatus: Deployed`, empty `ErrorMessage`. Bad: `Failed` with a populated `ErrorMessage` (read it directly — Azure only populates this field on failure, by design, so it's always actionable when present), or no status entry at all for the target region (never deployed there).

5. **If membership is dynamic (Azure Policy-based), account for evaluation lag before assuming a bug.** A VNet created moments ago will not instantly appear — allow the ~30-minute policy evaluation cycle (or up to 24 hours at >1,000-subscription scope) before escalating a "new VNet isn't picking up the config" ticket.

6. **If everything above looks correct and traffic still fails**, the problem has left AVNM's layer entirely — move to NSG evaluation (`NSG-B.md` Triage) and UDR/route-table review. AVNM's connectivity and security admin layers are necessary but not sufficient; NSGs still apply on top of whatever AVNM establishes.

---
## Common Fix Paths

<details><summary id="fix-1">Fix 1 — VNet not receiving any configuration (scope or never-deployed)</summary>

**Symptom:** Effective connectivity configuration is empty for a VNet you expect to be governed by AVNM.

```powershell
# Check 1: is the VNet's subscription/management-group actually within the network manager's delegated scope?
Get-AzNetworkManager -ResourceGroupName <nmRg> -Name <nm> | Select -ExpandProperty NetworkManagerScope

# Check 2: is the VNet a confirmed member of a network group used by a deployed configuration?
Get-AzNetworkManagerGroup -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Name <groupName>

# Check 3: was the configuration ever actually deployed to the VNet's region?
Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Region @("<vnetRegion>") -DeploymentType @("Connectivity")

# Fix: deploy (or re-deploy) the configuration to the correct region. Remember the goal-state rule —
# include every configuration you want to remain active in that region, not just the one you're fixing.
Deploy-AzNetworkManagerCommit -ResourceGroupName <nmRg> -Name <nm> `
  -TargetLocation @("<vnetRegion>") -ConfigurationId @("<connectivityConfigResourceId>") -CommitType @("Connectivity")
```

**Rollback:** Deploying a configuration is not destructive to the VNet itself — worst case is unwanted connectivity, correctable with another deploy. If a deploy created unwanted peerings/connected-group membership, redeploy without that configuration, or deploy `None` to the region to clear everything AVNM manages there.

</details>

<details><summary id="fix-2">Fix 2 — Dynamic membership hasn't caught up yet</summary>

**Symptom:** A newly created VNet that should match a dynamic (Azure-Policy-based) network group's condition isn't showing as a member yet.

```powershell
# Confirm the group's membership type and condition
Get-AzNetworkManagerGroup -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Name <groupName> |
  Select Name, MemberType, ConditionalMembership

# Confirm the VNet itself actually matches the condition (tag, subscription, resource group — whatever the policy checks)
Get-AzVirtualNetwork -ResourceGroupName <vnetRg> -Name <vnetName> | Select Tags, ResourceGroupName
```

Dynamic membership is driven by an Azure Policy assignment AVNM creates automatically behind the scenes. That policy's evaluation cycle runs roughly every 30 minutes — a brand-new VNet is not discovered the instant it's created. At environments with more than 1,000 subscriptions in scope, the notification window before AVNM is even told about the change can be up to 24 hours. **This is expected latency, not a bug** — don't escalate a "just created 10 minutes ago" ticket without waiting out at least one evaluation cycle first.

**Rollback:** N/A — no action taken, just a wait. If genuinely stuck after 24+ hours, verify the VNet actually matches the policy condition before assuming AVNM itself is broken.

</details>

<details><summary id="fix-3">Fix 3 — Goal-state redeploy trap (a previously-working config silently stopped applying)</summary>

**Symptom:** Config-B was working fine in a region. Someone modified and redeployed Config-A to the same region. Now Config-B's effects are gone too, even though nobody touched it.

**Root cause:** Azure Virtual Network Manager's deployment model is a **goal state**, not an incremental patch. Deploying to a region means "this is now the complete, exclusive set of configurations that should apply here." If the redeploy request only listed Config-A, Config-B — even though nothing about it changed — is removed from that region's enforced state.

```powershell
# Confirm what's currently, actually deployed to the region
Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Region @("<region>") -DeploymentType @("Connectivity")

# Fix: redeploy BOTH configurations together, every time, for any change in that region
Deploy-AzNetworkManagerCommit -ResourceGroupName <nmRg> -Name <nm> `
  -TargetLocation @("<region>") `
  -ConfigurationId @("<configA-ResourceId>", "<configB-ResourceId>") `
  -CommitType @("Connectivity")
```

**Prevention:** Before any deploy, list every configuration of that type currently active in the target region and include all of them in the deploy request — even ones you didn't intend to change. Document this in any client-facing change-management notes for AVNM; it is the single easiest way to cause an unannounced outage in this service.

**Rollback:** Redeploy the prior full set of configurations for that region to restore the previous goal state.

</details>

<details><summary id="fix-4">Fix 4 — "Use hub as gateway" silent partial-peering</summary>

**Symptom:** A hub-and-spoke connectivity configuration was deployed with "use hub as gateway" enabled, but spoke VNets can't route through the hub's VPN/ExpressRoute gateway — and the peering looks incomplete or one-sided.

**Root cause:** If "use hub as gateway" is enabled but no gateway actually exists yet in the hub VNet at deploy time, Azure Virtual Network Manager still creates the hub→spoke peering, but the spoke→hub peering (which requires referencing the gateway) **fails to create** — silently, with no deployment-level error surfaced for that specific resource (deployment status only reports overall success/failure, not per-peering detail).

```powershell
# Confirm a gateway actually exists in the hub VNet
Get-AzVirtualNetworkGateway -ResourceGroupName <hubRg> | Select Name, GatewayType, ProvisioningState

# Check peering state from both directions — this is the tell
Get-AzVirtualNetworkPeering -ResourceGroupName <hubRg> -VirtualNetworkName <hubVnetName>
Get-AzVirtualNetworkPeering -ResourceGroupName <spokeRg> -VirtualNetworkName <spokeVnetName>
```

**Fix:** Deploy the gateway in the hub VNet first, confirm `ProvisioningState: Succeeded`, then redeploy the connectivity configuration (remembering the goal-state rule from Fix 3 — include every other active configuration in that region too). Peering self-heals once the gateway exists; no manual peering repair is needed.

**Rollback:** N/A — this fix is additive (deploying a missing gateway), not destructive.

</details>

<details><summary id="fix-5">Fix 5 — Overlapping address space in a mesh</summary>

**Symptom:** Two VNets in the same mesh (connected group) can reach most of each other's address space, but traffic to one specific overlapping subnet range silently fails — no deny, just no response.

**Root cause:** Unlike virtual network peering, AVNM mesh topologies **allow overlapping address spaces by default**. When an overlap exists, Azure can't determine which VNet should receive traffic to that specific range, so it's dropped rather than routed — a routing ambiguity, not a security block, so nothing in NSG logs or effective security rules will show it.

```powershell
# Compare address spaces across mesh members
Get-AzNetworkManagerGroup -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Name <meshGroupName>
Get-AzVirtualNetwork -ResourceGroupName <vnetRg> -Name <vnetName> | Select AddressSpace
```

**Fix options, in order of preference:**
1. Re-IP one of the overlapping VNets (the durable fix — overlapping address space is an architectural problem AVNM can't route around, not a configuration bug).
2. If re-IP isn't feasible short-term, set the connectivity configuration's `ConnectedGroupAddressOverlap` property to `Disallowed` — this doesn't fix the overlap, but it makes AVNM actively reject any future attempt to add an overlapping VNet to the mesh, preventing the problem from silently growing while a permanent fix is planned.

**Rollback:** Setting `ConnectedGroupAddressOverlap` back to the default `Allowed` is non-destructive and instantly reversible.

</details>

---
## Escalation Evidence

Copy this template and fill in before escalating:

```
AVNM ESCALATION — <date/time>
Network Manager: <name>   Resource Group: <rg>   Scope: <management group / subscription list>
Affected VNet: <name>   Resource Group: <rg>   Region: <region>

Expected topology: <mesh / hub-and-spoke>   Configuration name: <connectivityConfigName>
Network group membership type: <static / dynamic>   Confirmed member? <yes/no, when checked>

Effective connectivity configuration output (attach or paste):
  Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName <vnet> -VirtualNetworkResourceGroupName <rg>

Deployment status output (attach or paste):
  Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Region @("<region>") -DeploymentType @("Connectivity")

Recent configuration changes in this region (who/what/when, from activity log or change record):
  <details or "none found">

Security Admin Rules checked separately? <Yes — see NSG-B.md triage / No>

What's been tried:
  <bullet list>

Business impact / urgency:
  <one line>
```

---
## 🎓 Learning Pointers

- **A mesh topology never shows up as a virtual network peering.** It's realized as a "connected group," an AVNM-native construct — effective routes show next-hop type `ConnectedGroup`, not `VNetPeering`/`GlobalVNetPeering`. Looking in the Peerings blade for a mesh connection is the single most common false-negative in this topic. See [Connectivity configurations](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-connectivity-configuration).
- **The goal-state deployment model is additive-and-exclusive per region, not incremental.** Redeploying Config-A without also including already-active Config-B removes Config-B from that region. Any change process touching AVNM must always enumerate and re-include every active configuration of that type for the target region. See [Manage configuration deployments](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-deployments).
- **Scope is a hard, silent ceiling.** A VNet can be a network group member and still receive nothing if its subscription/management group falls outside the network manager's delegated scope — this is explicitly the #2 troubleshooting question in Microsoft's own FAQ, right after "was it deployed."
- **Dynamic (Azure-Policy-based) group membership has real latency** — roughly a 30-minute evaluation cycle, up to 24 hours at >1,000-subscription scope. Don't chase a "new VNet isn't picking up policy" ticket as a bug before that window has passed.
- **"Use hub as gateway" fails silently, one direction only, if the hub's gateway doesn't exist yet at deploy time.** The hub→spoke peering is created regardless; only the spoke→hub leg (which depends on the gateway) fails. Deploy the gateway first, then the connectivity configuration.
- **Security Admin Rules are a separate configuration type from connectivity configurations, evaluated earlier in the packet path, and fully documented in `NSG-A.md`/`NSG-B.md` rather than here** — if effective connectivity configuration looks correct and traffic is still blocked, that's where to look next, not back into this topic. See [Security admin rules](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-security-admins).
