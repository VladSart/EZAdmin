# Azure Virtual Network Manager — Reference Runbook (Mode A: Deep Dive)
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

Covers **Azure Virtual Network Manager (AVNM)** as a centralized network governance service: the network manager instance and its scope/delegation model, network groups (static and dynamic/Azure-Policy-based membership), connectivity configurations (mesh and hub-and-spoke topologies, including the Virtual WAN hub preview), the connected-group construct, the deployment/goal-state model, and the standard troubleshooting decision tree for "my VNet isn't receiving the configuration I expect."

Does **not** cover: **Security Admin Rules** mechanics — evaluation order, action types (Allow/AlwaysAllow/Deny), rule collections, and how they intersect NSG evaluation are fully documented in `NSG-A.md`'s "Security Admin Rules (Azure Virtual Network Manager)" section and `NSG-B.md`'s Triage/Fix paths; this file covers Security Admin Rules only as one of three configuration *types* AVNM can deploy, not their internal rule logic. Also does not cover **IP Address Management (IPAM)**, a related but functionally independent AVNM feature (centralized IP pool allocation across subscriptions) that is billed and operated separately from connectivity/security configurations and has no MSP-ticket history in this repo yet. Also does not cover the underlying VPN Gateway/ExpressRoute/NSG mechanics that AVNM configurations ultimately act upon — see `HybridConnectivity-A.md` and `NSG-A.md` respectively.

---
## How It Works

<details><summary>Full architecture</summary>

**The core idea.** Azure Virtual Network Manager is a centralized control plane that sits *above* individual VNets, NSGs, and peerings. Instead of an engineer manually creating a peering or NSG rule on every VNet in a growing estate, a central network team defines **network groups** (which VNets are governed), **configurations** (what should apply to them — connectivity topology, security admin rules, or routing), and **deploys** those configurations to specific Azure regions. AVNM then continuously reconciles the actual state of governed VNets to match.

**Scope and delegation.** A network manager instance is created at, and delegated authority over, a specific **scope** — one or more subscriptions, or a management group (which implicitly covers every subscription beneath it). This scope is a hard ceiling: "a network manager is delegated only enough access to apply configurations to virtual networks within your scope. If a resource is in your network group but out of scope, it doesn't receive any configurations" — silently, with no error surfaced anywhere. A VNet can belong to more than one network manager instance simultaneously (e.g., one for connectivity governed by a platform team, another for security admin rules governed by a security team), and a VNet from a subscription you don't directly manage can still be added if you have appropriate access to it. What a network manager instance **cannot** do: move between regions, resource groups, or subscriptions once created (delete and recreate is the only path), or have its parent subscription moved to a different Microsoft Entra tenant.

**Network groups — the "which VNets" layer.** A network group is a named collection of VNets, populated one of two ways:
- **Static membership** — VNets added manually, one at a time. Takes effect immediately. The *only* option for VNets in a different Microsoft Entra tenant than the network manager (cross-tenant VNets cannot use dynamic/Azure-Policy-based membership at all).
- **Dynamic membership** — an Azure Policy-based condition (subscription, resource group, tag, or other resource property) that AVNM evaluates continuously. When a network group is set to dynamic, AVNM creates an Azure Policy assignment behind the scenes to detect membership changes. This assignment does **not** run on the standard Azure Policy compliance evaluation cycle — it runs roughly every 30 minutes for environments up to 1,000 subscriptions in scope; beyond that, the policy notification to AVNM itself can take up to 24 hours, after which the actual configuration application still only takes a few minutes. A VNet added to a group with an already-deployed active configuration receives that configuration automatically once membership updates — no redeployment needed.

**Configurations — the "what" layer.** Three configuration types exist, and this is the one place their relationship matters even though only connectivity is covered in depth here:
- **Connectivity configurations** — mesh or hub-and-spoke topology (this file's main subject).
- **Security admin configurations** — network-security rules evaluated before any NSG, capable of unconditionally allowing or denying traffic regardless of NSG state (fully covered in `NSG-A.md`).
- **Routing configurations** — centrally managed route tables/UDRs pushed to governed VNets (out of scope here; no MSP-ticket history yet in this repo).

A configuration object existing in the portal or returned by `Get-AzNetworkManagerConnectivityConfiguration` **does nothing by itself.** It is inert metadata until deployed.

**Connectivity configuration topologies.**

*Mesh* — every VNet in the targeted network group(s) gets bidirectional connectivity to every other member. Regional by default (only same-region VNets connect); a "global mesh" option extends this across all Azure regions. Mesh connectivity is realized as a **connected group** — see below, not a peering.

*Hub-and-spoke* — a single hub (either a hub VNet, or, in preview, a Virtual WAN hub) connects to every VNet in one or more selected "spoke" network groups. If the hub is a VNet, AVNM creates real virtual network peerings between hub and each spoke. If the hub is a Virtual WAN hub (preview, limited region availability), AVNM creates or updates Virtual WAN virtual network connections instead. Optional settings layered on top:
  - **Direct connectivity** — enabling this for a spoke network group creates a mesh (connected group) *among that group's own members*, so spokes in the same group can talk to each other without transiting the hub. It does **not** extend to spokes in a different network group even within the same hub-and-spoke configuration — two network groups (e.g. "Production" and "Test") both connected to the same hub remain isolated from each other unless direct connectivity is separately enabled for each and they're the same group.
  - **Use hub as gateway** — lets spoke VNets use a VPN/ExpressRoute gateway deployed in the hub, via gateway transit. Enabled by default when deploying from the portal. If no gateway exists in the hub at deploy time, the hub→spoke peering is still created, but the spoke→hub peering (which requires the gateway reference) fails to create — a genuinely silent, one-sided partial deployment (see `AVNM-B.md` Fix 4).
  - **Peering enforcement** — an optional governance setting (`peeringEnforcement: Enforced`) that prevents peerings created by (or already existing within) the topology from being deleted or modified outside AVNM. Applies to preexisting customer-created peerings too, not just AVNM-created ones.

**Connected groups — the construct behind mesh and direct connectivity.** This is not a virtual network peering. It's an AVNM-native connectivity construct: all member VNets are mutually reachable without any pairwise peering relationship existing between them. Effective routes on a NIC in a connected-group VNet show next-hop type `ConnectedGroup`, and the member VNets show **no entry at all** under their own Peerings blade for this connectivity — a portal-based "did the peering work" check will always come back empty for mesh/direct-connectivity traffic, which is the most common false-negative in this whole topic. Connected groups exist specifically to scale beyond traditional peering's pairwise-relationship model: a VNet can be part of up to **two** connected groups by default (e.g., a mesh plus a hub-and-spoke's direct-connectivity mesh), a connected group can contain up to 250 VNets by default (soft limit, raisable to 1,000 by request), and a "high-scale connected group" preview feature raises that further to 5,000 VNets in supported regions. IP address ranges within a connected group can overlap by default — but traffic addressed to the overlapping range is **dropped**, not misrouted, since Azure has no deterministic way to decide which VNet should receive it. Setting the connectivity configuration's `ConnectedGroupAddressOverlap` property to `Disallowed` makes AVNM actively reject any VNet whose address space would overlap an existing mesh member, trading flexibility for an up-front validation guarantee.

**Deployment and the goal-state model.** Configurations take effect only once **deployed** to one or more specific Azure regions — this is a deliberate, explicit commit action, not an implicit save. Deployment computes a **goal state**: the combination of every configuration deployed to that region plus current network group membership. Critically, this model is **exclusive per region, not additive across deploy actions** — if region East US currently has Config1 and Config2 deployed, and someone deploys just Config1 again (e.g., after modifying it), Config2 is **removed** from that region's goal state, even though nobody touched Config2 directly. Every deploy action must explicitly re-include every configuration of that type meant to remain active in the target region. To remove all AVNM-managed configuration from a region entirely, deploy `None` to it.

Timing: the base time to apply a configuration once deployment is committed is a few minutes. Network group membership changes (not the configuration itself) propagate on the static-immediate/dynamic-with-Azure-Policy-lag timeline described above, and once membership updates, previously active configurations apply to newly added members automatically without a fresh deploy.

Deployment status only reports overall region-level success/failure via `DeploymentStatus` (`Deployed`/`Deploying`/`Failed`) and, on failure only, a populated `ErrorMessage` — Azure deliberately does not surface per-resource (individual VNet/peering/subnet) failure detail at this level, "to ensure customers focus on actionable errors." Resource-level detail requires checking the resource itself (e.g., the hub's peering status directly, per Fix 4 in `AVNM-B.md`).

**Region availability and blast radius.** The network manager instance itself lives in one region, but that's an administrative detail, not a connectivity dependency — if the instance's own region goes down, you lose the ability to create or modify configurations, but configurations already deployed to *other* healthy regions keep functioning. Only an outage in a region containing governed VNets themselves affects the configurations deployed to *that* region specifically.

**Cost model.** Since February 2025, AVNM charges per VNet with an *active deployed* configuration (any type), not per subscription in scope — a network manager scoped to 100 VNets but with configurations deployed onto only 5 of them is billed for 5. Multiple configurations from the *same* network manager instance on the same VNet don't multiply the charge; multiple configurations from *different* network manager instances on the same VNet do. Network Verifier (reachability analysis) and IP Address Management are both billed as separate, independent features.

</details>

---
## Dependency Stack

```
Layer 6 — Effective state on the VNet
          (Get-AzNetworkManagerEffectiveConnectivityConfiguration / -EffectiveSecurityAdminRule —
           the only fully authoritative view; everything below this is "configured intent," not "applied reality")
              ▲
Layer 5 — Underlying construct realized
          Mesh / direct-connectivity → Connected Group (AVNM-native, invisible in Peerings blade)
          Hub-and-spoke w/ hub VNet  → real virtual network peering
          Hub-and-spoke w/ VWAN hub  → Virtual WAN virtual network connection (preview)
              ▲
Layer 4 — Deployment (per-region commit, goal-state, exclusive-not-additive across deploy actions)
              ▲
Layer 3 — Configuration object defined (connectivity / security admin / routing) — inert until deployed
              ▲
Layer 2 — Network Group membership
          Static (manual, immediate) or Dynamic (Azure Policy-based, ~30 min eval cycle,
          up to 24h notification lag at >1,000-subscription scope)
              ▲
Layer 1 — Network Manager instance scope & delegation
          Management group or subscription(s) — a hard ceiling; out-of-scope VNets receive
          nothing even if group-listed. Cannot span tenants; cannot be moved once created.
```

A failure at any layer produces the *same* downstream symptom — "the VNet isn't getting the connectivity I configured" — which is exactly why Layer 6 (effective state) is always the first diagnostic pull, not the last: it tells you definitively whether the problem is above or below it before you guess.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| VNet in the right network group, configuration looks correct, effective config is empty | Configuration never deployed to that region | `Get-AzNetworkManagerDeploymentStatus` for the target region/type |
| Same as above, but VNet's subscription was recently moved into the target management group | VNet is out of the network manager's delegated **scope**, not just the group | `Get-AzNetworkManager` → `NetworkManagerScope` |
| Newly created VNet with matching tags doesn't show as a dynamic group member yet | Azure Policy evaluation lag (~30 min, up to 24h at scale) | Wait one evaluation cycle; confirm tag/condition match directly |
| Mesh/direct-connectivity VNets can't find a peering for their connection | Not a bug — mesh is a **connected group**, never a peering resource | `Get-AzNetworkManagerEffectiveConnectivityConfiguration`, effective routes next-hop `ConnectedGroup` |
| Hub→spoke peering exists, spoke→hub doesn't | "Use hub as gateway" enabled before a gateway existed in the hub | `Get-AzVirtualNetworkGateway` on the hub; confirm `ProvisioningState: Succeeded` |
| A previously-working configuration in a region stopped applying after an unrelated change | Goal-state redeploy trap — the unrelated deploy omitted this configuration | `Get-AzNetworkManagerDeploymentStatus`; compare configured vs. currently-deployed set |
| Two mesh VNets can reach most of each other but not one specific subnet range | Overlapping address space between mesh members — traffic to overlap silently dropped | Compare `AddressSpace` across mesh members |
| A configuration exists in the portal but nothing ever happened | Never deployed — configuration objects are inert until committed | `Get-AzNetworkManagerConnectivityConfiguration` exists but no matching deployment status |
| Deployment status shows `Failed` | Read `ErrorMessage` directly — Azure only populates it on failure, so it's always actionable when present | `Get-AzNetworkManagerDeploymentStatus` |
| VNet belongs to two different network managers with conflicting connectivity intents | Both are independently valid and independently deployed — check effective config against each manager separately | Confirm which network manager owns which configuration via resource ID |
| Security admin rule seems to override connectivity entirely (traffic blocked despite mesh/peering existing) | Different configuration type, evaluated earlier — not a connectivity-configuration problem | See `NSG-A.md`/`NSG-B.md` — do not troubleshoot as a connectivity issue |
| Cross-tenant VNet won't join a dynamic network group | Not supported — cross-tenant VNets can only use static membership | `Get-AzNetworkManagerGroup` → `MemberType` |
| VNet contains Azure SQL Managed Instance or Azure Databricks, security admin rules aren't applying | Nonapplication-by-design for these services' network intent policies | `AllowRulesOnly` on `securityConfiguration.properties.applyOnNetworkIntentPolicyBasedServices` if only Allow rules are needed |
| A subnet with Application Gateway, Bastion, Firewall, Route Server, VPN Gateway, Virtual WAN, or ExpressRoute Gateway isn't receiving security admin rules | Documented nonapplication list at the subnet level for these specific services | Confirm against Microsoft's nonapplication list before assuming misconfiguration |

---
## Validation Steps

1. **Confirm network manager scope covers the target VNet's subscription.**
   ```powershell
   Get-AzNetworkManager -ResourceGroupName <nmRg> -Name <nm> | Select -ExpandProperty NetworkManagerScope
   ```
   Good: target subscription (or its management group) listed. Bad: target subscription absent — everything downstream is moot until scope is expanded.

2. **Confirm network group membership and its type.**
   ```powershell
   Get-AzNetworkManagerGroup -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Name <groupName>
   ```
   Good: `MemberType` matches expectation (Static/Dynamic) and, for dynamic groups, the VNet's tags/properties genuinely satisfy `ConditionalMembership`.

3. **Confirm the connectivity configuration exists and targets the right network group(s).**
   ```powershell
   Get-AzNetworkManagerConnectivityConfiguration -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Name <configName>
   ```
   This confirms *intent* only — proceed to deployment status and effective config before concluding anything works.

4. **Confirm deployment status for the target region and configuration type.**
   ```powershell
   Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <nm> -Region @("<region>") -DeploymentType @("Connectivity")
   ```
   Good: `DeploymentStatus: Deployed`. Bad: `Failed` (read `ErrorMessage`) or no entry for the region at all.

5. **Pull effective connectivity configuration — the authoritative ground truth.**
   ```powershell
   Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName <vnetName> -VirtualNetworkResourceGroupName <vnetRg>
   ```
   Good: the expected configuration ID appears. Bad: empty (nothing applying) or a stale/unexpected configuration ID (goal-state drift).

6. **For mesh/direct-connectivity, confirm via effective routes, not the Peerings blade.**
   ```powershell
   Get-AzEffectiveRouteTable -ResourceGroupName <rg> -NetworkInterfaceName <nicName>
   ```
   Good: a route to the peer VNet's address space with `NextHopType: ConnectedGroup`. A missing peering resource is expected and not itself a fault.

7. **For hub-and-spoke with "use hub as gateway," confirm the gateway exists and both peering legs are complete.**
   ```powershell
   Get-AzVirtualNetworkGateway -ResourceGroupName <hubRg>
   Get-AzVirtualNetworkPeering -ResourceGroupName <hubRg> -VirtualNetworkName <hubVnet>
   Get-AzVirtualNetworkPeering -ResourceGroupName <spokeRg> -VirtualNetworkName <spokeVnet>
   ```
   Good: gateway `ProvisioningState: Succeeded`, peering `PeeringState: Connected` in both directions.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Scope and deployment (rule out the two most common silent failures first).**
Confirm the VNet's subscription is within network manager scope (Validation Step 1), then confirm the configuration was actually deployed to the VNet's region (Validation Step 4). Skipping straight to configuration content review before these two checks is the single most common wasted-time pattern in this topic — both fail with zero visible error.

**Phase 2 — Membership timing.**
If the VNet was added or changed recently and uses dynamic (Azure-Policy-based) group membership, confirm whether enough time has passed for the policy evaluation cycle (~30 min, up to 24h at >1,000-subscription scope) before treating this as a defect.

**Phase 3 — Effective state, not configured intent.**
Pull `Get-AzNetworkManagerEffectiveConnectivityConfiguration` directly rather than reasoning from the portal's configuration screens. This single command resolves the majority of "is it even applying" questions definitively.

**Phase 4 — Topology-specific checks.**
For mesh: confirm via effective routes (`NextHopType: ConnectedGroup`), not the Peerings blade. For hub-and-spoke: confirm the hub's gateway exists if "use hub as gateway" is enabled, and check both peering directions independently — a one-sided peering is the topology's signature failure mode.

**Phase 5 — Goal-state audit.**
If a previously-working configuration stopped applying after an unrelated deploy, list every configuration currently active in that region via deployment status, and confirm the most recent deploy request for that region included all of them. This is a process gap, not a bug, and the fix is procedural (always enumerate before redeploying) as much as it is a one-time redeploy.

**Phase 6 — Escalate to NSG/routing layer only after AVNM's own layers are confirmed correct.**
If effective connectivity configuration and effective security admin rules both look correct and traffic still fails, the fault has left this topic. Hand off to `NSG-B.md` Triage and standard UDR/route-table review — don't keep re-checking AVNM configuration that's already confirmed to be applying as intended.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate an existing manually-peered hub-and-spoke into AVNM management</summary>

Azure Virtual Network Manager is explicitly designed to coexist with and adopt pre-existing manual peerings — this is a documented, zero-downtime migration path, not a rip-and-replace.

1. Create the network manager instance at a scope covering the hub and all spoke subscriptions.
2. Create a hub-and-spoke connectivity configuration referencing the existing hub VNet and a network group containing the existing spoke VNets (static membership is simplest for an initial migration; convert to dynamic afterward if desired).
3. Deploy the configuration to the relevant region(s). AVNM detects the pre-existing peerings, leaves them intact, and begins managing them going forward — "any preexisting peerings remain intact, so there's no downtime."
4. Optionally enable **peering enforcement** (`peeringEnforcement: Enforced`) once migration is confirmed stable, to prevent drift from manual out-of-band peering changes going forward. This applies to the pre-existing peerings too, not just newly created ones — communicate this to any team that previously had direct peering-edit access, since their manual changes will now be blocked.

**Rollback:** Deploy `None` to the affected regions to remove AVNM management; manually created peerings that predate AVNM are not deleted by this action (AVNM only removes connectivity it itself created), so connectivity is preserved even after disengaging AVNM.

</details>

<details><summary>Playbook 2 — Recovering from a goal-state configuration drop</summary>

Use when a client reports a previously-working AVNM-managed connection (mesh or hub-and-spoke) that broke coincident with an unrelated network change.

1. Identify the affected region and configuration type (`Connectivity` vs. `SecurityAdmin`) via `Get-AzNetworkManagerDeploymentStatus`.
2. List **every** configuration of that type that should be active in that region — cross-reference against `Get-AzNetworkManagerConnectivityConfiguration` for all configurations targeting network groups with members in that region, not just the one reported broken.
3. Redeploy the complete set together in a single `Deploy-AzNetworkManagerCommit` call, explicitly listing every configuration ID.
4. Confirm recovery via effective connectivity configuration on a representative affected VNet, not just deployment status (deployment status can show `Deployed` successfully while still representing an incomplete goal state if a configuration was legitimately omitted on purpose by whoever ran the prior deploy).
5. Document the incident and add a pre-deploy checklist step ("list all active configs in this region before any deploy") to prevent recurrence — this is a process gap, and the same mistake will repeat without one.

**Rollback:** N/A — this playbook is itself the recovery action.

</details>

<details><summary>Playbook 3 — Expanding connected-group scale limits</summary>

Use when a mesh or direct-connectivity spoke group is approaching AVNM's default scale ceilings: 250 VNets per connected group (soft limit), or a VNet needing to participate in more than 2 connected groups simultaneously.

1. Confirm the actual limit being approached — check current connected-group VNet count against 250, and confirm whether the "more than 2 connected groups" limit applies (e.g., a VNet in two separate mesh configurations plus a hub-and-spoke direct-connectivity group would need a third).
2. Both the 250-VNet connected-group limit (raisable to 1,000) and the 2-connected-group-per-VNet limit are **soft limits raisable by request**, not hard architectural ceilings — submit the appropriate Microsoft request form referenced in the [service limitations documentation](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-limitations) well ahead of the client's growth timeline, since this is a support-ticket-driven increase, not a self-service portal toggle.
3. For very large fleets (thousands of VNets), also evaluate the "high-scale connected group" preview feature (up to 5,000 VNets, requires registering the `AllowHighScaleConnectedGroup` preview feature) and, separately, "high-scale private endpoints" (up to 20,000 private endpoints per connected group) if the workload is private-endpoint-heavy — these are independent preview toggles, not automatic at scale.
4. Set client expectations that both increases are Microsoft-support-mediated, not instant, and should be requested during capacity planning rather than during an active incident.

**Rollback:** N/A — this is a capacity-planning playbook, not a destructive or reversible-in-place action.

</details>

<details><summary>Playbook 4 — Fleet-wide AVNM configuration health sweep (MSP multi-client)</summary>

Use for a periodic governance check across every network manager instance an MSP manages on behalf of clients.

1. Run `Scripts/Get-AVNMConfigAudit.ps1` against each client subscription/tenant to inventory network managers, network groups (flagging empty groups), connectivity configurations, and deployment status per region.
2. Cross-reference every connectivity configuration against its deployment status — any configuration with **zero** deployed regions is dead weight (defined but never actually applied) and either needs deployment or removal to avoid confusing future engineers.
3. Flag any region with more than one connectivity configuration deployed as a goal-state risk area — document the full active set for that region in client-facing runbook notes so a future single-configuration redeploy doesn't silently drop the others (Fix 3 / Playbook 2 above).
4. For dynamic network groups, spot-check that the Azure Policy condition still matches the client's current tagging/naming convention — client-side tagging drift (a renamed tag, a changed naming standard) silently shrinks dynamic group membership over time with no alert.

**Rollback:** N/A — read-only audit playbook.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects AVNM evidence for a specific VNet ahead of escalation — scope, group membership,
    configured intent, deployment status, and effective (authoritative) state in one pass.
#>
param(
    [Parameter(Mandatory)][string]$NetworkManagerResourceGroup,
    [Parameter(Mandatory)][string]$NetworkManagerName,
    [Parameter(Mandatory)][string]$VNetName,
    [Parameter(Mandatory)][string]$VNetResourceGroup,
    [Parameter(Mandatory)][string]$Region
)

$evidence = [ordered]@{
    NetworkManager       = Get-AzNetworkManager -ResourceGroupName $NetworkManagerResourceGroup -Name $NetworkManagerName
    ConnectivityConfigs   = Get-AzNetworkManagerConnectivityConfiguration -ResourceGroupName $NetworkManagerResourceGroup -NetworkManagerName $NetworkManagerName
    ConnectivityDeploy    = Get-AzNetworkManagerDeploymentStatus -ResourceGroupName $NetworkManagerResourceGroup -NetworkManagerName $NetworkManagerName -Region @($Region) -DeploymentType @("Connectivity")
    SecurityAdminDeploy   = Get-AzNetworkManagerDeploymentStatus -ResourceGroupName $NetworkManagerResourceGroup -NetworkManagerName $NetworkManagerName -Region @($Region) -DeploymentType @("SecurityAdmin")
    EffectiveConnectivity = Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName $VNetName -VirtualNetworkResourceGroupName $VNetResourceGroup
    EffectiveSecurityAdmin = Get-AzNetworkManagerEffectiveSecurityAdminRule -VirtualNetworkName $VNetName -VirtualNetworkResourceGroupName $VNetResourceGroup
    VNetAddressSpace      = (Get-AzVirtualNetwork -ResourceGroupName $VNetResourceGroup -Name $VNetName).AddressSpace
}

$evidence | ConvertTo-Json -Depth 6 | Out-File "AVNM-Evidence-$VNetName-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
Write-Host "Evidence pack written." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-AzNetworkManager -ResourceGroupName <rg> -Name <nm>` | Instance details, scope, scope access types |
| `Get-AzNetworkManagerGroup -ResourceGroupName <rg> -NetworkManagerName <nm> -Name <group>` | Network group membership type and condition |
| `Get-AzNetworkManagerStaticMember -ResourceGroupName <rg> -NetworkManagerName <nm> -NetworkGroupName <group>` | List static members explicitly |
| `Get-AzNetworkManagerConnectivityConfiguration -ResourceGroupName <rg> -NetworkManagerName <nm>` | Configured (not yet necessarily deployed) connectivity intent |
| `Get-AzNetworkManagerSecurityAdminConfiguration -ResourceGroupName <rg> -NetworkManagerName <nm>` | Configured security admin intent (see `NSG-A.md` for rule internals) |
| `Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <rg> -NetworkManagerName <nm> -Region @(<region>) -DeploymentType @("Connectivity")` | Per-region deployment success/failure and error detail |
| `Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName <vnet> -VirtualNetworkResourceGroupName <rg>` | **The** authoritative "what's actually applied" view |
| `Get-AzNetworkManagerEffectiveSecurityAdminRule -VirtualNetworkName <vnet> -VirtualNetworkResourceGroupName <rg>` | Authoritative security admin rule state on a VNet |
| `Deploy-AzNetworkManagerCommit -ResourceGroupName <rg> -Name <nm> -TargetLocation @(<region>) -ConfigurationId @(<id>,...) -CommitType @("Connectivity")` | Commit a deployment — always list every config to remain active |
| `Get-AzEffectiveRouteTable -ResourceGroupName <rg> -NetworkInterfaceName <nic>` | Confirm `ConnectedGroup` next-hop for mesh/direct-connectivity traffic |
| `Get-AzVirtualNetworkGateway -ResourceGroupName <hubRg>` | Confirm hub gateway exists before trusting "use hub as gateway" peering |
| `Get-AzVirtualNetworkPeering -ResourceGroupName <rg> -VirtualNetworkName <vnet>` | Check hub-and-spoke peering state from both directions |
| `Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnet> \| Select AddressSpace` | Compare address spaces for mesh overlap troubleshooting |
| `Get-AzNetworkManagerEffectiveVirtualNetwork -VirtualNetworkName <vnet> -VirtualNetworkResourceGroupName <rg>` | Enumerate which network group memberships a VNet effectively has |

---
## 🎓 Learning Pointers

- **The scope/delegation model is a hard, silent ceiling — always the first thing to rule out, before touching configuration content.** A VNet can be a correct network group member and still receive nothing if its subscription falls outside the network manager's delegated management-group/subscription scope. See [Network Manager scope](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-network-manager-scope).
- **Deployment is a goal-state commit, not an incremental patch.** Every deploy to a region replaces that region's entire enforced set for that configuration type — omitting an unrelated, previously-active configuration removes it. This is the single easiest way to cause an unannounced client-facing outage in this service, and it's a process discipline problem as much as a technical one. See [Manage configuration deployments](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-deployments).
- **Mesh and direct-connectivity topologies are realized as "connected groups," never as virtual network peerings.** Checking the Peerings blade for this traffic will always come back empty — the correct verification is effective routes (`NextHopType: ConnectedGroup`) or `Get-AzNetworkManagerEffectiveConnectivityConfiguration`. See [Connectivity configurations — behind the scenes](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-connectivity-configuration#behind-the-scenes-connected-group).
- **Dynamic network group membership runs on Azure Virtual Network Manager's own evaluation cadence (~30 minutes, up to 24 hours at >1,000-subscription scope), not the standard Azure Policy compliance cycle.** A "just-created VNet isn't showing up" ticket is very often just this lag, not a defect.
- **"Use hub as gateway" has a one-sided silent failure mode if the hub's gateway doesn't exist at deploy time** — the hub→spoke peering succeeds, spoke→hub fails, and nothing in deployment status calls this out at the individual-peering level. Always confirm gateway `ProvisioningState` before deploying a configuration that depends on it.
- **Security admin rules don't apply to every resource — there's a documented nonapplication list** (Azure SQL Managed Instance and Azure Databricks at the VNet level via network intent policy conflicts; Application Gateway, Bastion, Firewall, Route Server, VPN Gateway, Virtual WAN, and ExpressRoute Gateway at the subnet level). A "my Deny rule isn't blocking this specific subnet" ticket involving any of these services may be expected behavior, not a bug — see [Frequently asked questions](https://learn.microsoft.com/en-us/azure/virtual-network-manager/faq) and [Security admin rules — nonapplication](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-security-admins#nonapplication-of-security-admin-rules).
