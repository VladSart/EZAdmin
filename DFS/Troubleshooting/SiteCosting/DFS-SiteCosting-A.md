# DFS Referral Ordering & Site Costing — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Domain-based DFS Namespaces (v2, Windows Server 2008+) with two or more folder targets per folder
- AD Sites and Services topology: sites, subnets, site links, and their costs
- Referral ordering algorithm as implemented in DFSN (`Dfsutil.exe`, `Get/Set-Dfsn*` cmdlets)
- Multi-site or hub-and-spoke WAN environments where users at branch sites should prefer local file servers

**Out of scope:**
- DFSR replication health (see `Replication-A.md`) — this document assumes replication is healthy and both targets have current data
- Standalone (non-AD) namespaces — these have no site awareness at all
- Client-side WAN acceleration / SMB Direct — orthogonal to referral selection

**Assumes:**
- Domain Admin or delegated AD Sites and Services rights
- RSAT DFS Management + ActiveDirectory PowerShell modules
- At least two AD sites with a defined site link topology

---
## How It Works

<details><summary>Full architecture — the referral algorithm end to end</summary>

### Why referral ordering exists

A DFS folder with multiple targets (e.g., a folder replicated to a hub file server and three branch file servers) needs to tell each client which target to use *first*. Without this, a client in Branch A could be handed the Branch C server as its primary target — technically working, but crossing a WAN link for every file open. Referral ordering exists purely to make that choice AD-topology-aware instead of arbitrary.

### The three inputs to ordering

1. **Manual priority overrides** (`ReferralPriorityClass` / `ReferralPriorityRank` on each folder target) — set per-target in DFS Management under a folder's Properties → Referrals tab, or via `Set-DfsnFolderTarget`. Classes: `GlobalHigh` > `SiteCost` (with rank) > `GlobalLow`. These exist to permanently prefer or exclude a target (e.g., pin a DR server as always-last) regardless of topology.
2. **AD site membership** — every namespace server and folder target server has a fixed AD site (determined by the subnet its IP falls into, per `Get-ADReplicationSubnet`). Every client likewise resolves to a site the same way.
3. **AD site link cost** — the `Cost` attribute on each `Get-ADReplicationSiteLink` object defines the "distance" between two sites. Lower cost = preferred path. Costs are also used by the KCC for AD replication topology, so they are never DFS-exclusive settings — changing them has AD-wide blast radius.

### The ordering algorithm (in precedence order)

```
For each client request:
  1. Apply GlobalHigh targets first, in ReferralPriorityRank order
  2. Apply SiteCost-class targets:
       a. Same site as client → cost 0 → always first among SiteCost targets
       b. Different site → order ascending by cheapest site-link path
          (Dijkstra-style lowest-cost path across the site-link graph,
           computed by the DC/GC servicing the referral, using cached
           ISTG/KCC topology data — NOT recalculated live per request)
       c. Equal-cost targets → randomized order (load spreading)
  3. Apply GlobalLow targets last, in ReferralPriorityRank order
  4. If namespace-level "Exclude targets outside of the client's site" is
     enabled, any non-same-site target is dropped from the list entirely
     rather than just de-prioritized
```

### Referral caching

Clients don't ask for a referral on every file operation — that would be pathologically chatty. Instead:
- The client caches the ordered target list per DFS path after first referral, governed by `DfsDcTimeout`/`TargetListTTL` (registry: `HKLM\SYSTEM\CurrentControlSet\Services\Mup\DfsDcTimeout`, PDC/namespace default ~1800 seconds for folder referrals, ~15 min for domain referrals)
- `dfsutil /pktinfo` dumps the client's live referral cache — this is the ground truth for what the client will actually do, independent of what AD *should* produce
- `dfsutil /pktflush` clears it, forcing a fresh referral lookup on next access

### Where "site" actually comes from

A client is **not** assigned a site directly. Netlogon determines site membership by matching the client's IP address against `Get-ADReplicationSubnet` objects, each of which maps a CIDR range to exactly one site. If a client's IP falls in no defined subnet, it is treated as sitting in the site of whichever DC happened to answer its DC-locator request — effectively undefined, and a frequent silent cause of "random" referral behavior that looks like a DFS bug but is a missing-subnet-object problem.

</details>

---
## Dependency Stack

```
Layer 5:  Client-cached referral list (dfsutil /pktinfo)  — TTL-bound, can be stale
Layer 4:  DFSN referral response ordering algorithm       — priority > site-cost > random
Layer 3:  Folder target manual priority overrides         — GlobalHigh/SiteCost/GlobalLow
Layer 2:  AD Site Link costs (Get-ADReplicationSiteLink)  — shared with AD replication topology
Layer 1:  AD Site membership per server & client          — from Subnet→Site mapping
Layer 0:  AD Subnet objects (Get-ADReplicationSubnet)      — the actual source of truth
```

A misconfiguration at Layer 0 (missing subnet) silently breaks every layer above it, and looks identical from the client's perspective to a Layer 3 (manual override) problem — same symptom, opposite root cause, opposite fix. This is why the Diagnosis phases below always start at Layer 0 and work upward.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| One branch site's users are all slow, other branches fine | Missing/wrong subnet object for that branch's IP range | `Get-ADReplicationSubnet` — confirm mapping exists and matches the branch's actual CIDR |
| All users at a site intermittently get routed to different targets on different days | Client is falling in the "no subnet match" fallback and picking up whichever DC answers, or two subnets accidentally overlap | `nltest /dsgetsite` on multiple clients at the same site over time — inconsistent results confirm this |
| A specific single folder always sends everyone to the DR/hub server first | Manual `GlobalHigh` priority override left on the wrong target after a migration or DR test | `Get-DfsnFolderTarget -Path <path> \| select TargetPath,ReferralPriorityClass,ReferralPriorityRank` |
| Referral order looks right in `Get-DfsnFolderTarget` but client still uses the wrong server | Stale client-side referral cache | `dfsutil /pktinfo`, then `dfsutil /pktflush` and retest |
| Two branches that should both prefer the hub over each other are instead routing branch-to-branch | Site link topology has a lower-cost path between the two branch sites than either has to the hub | `Get-ADReplicationSiteLink -Properties Cost,SitesIncluded` — map the full graph, not just the two links you expect |
| Referral order looks correct for domain-joined PCs but wrong for a specific subnet of newly added DHCP scope | New DHCP scope's subnet was never added as an AD subnet object | `Get-ADReplicationSubnet` vs. actual DHCP scope range |
| Referrals are effectively random across all sites, with no site preference at all | Namespace's Referral Ordering Method is set to "Random order" or "Exclude targets outside client's site" is misapplied at the root instead of per-folder | DFS Management → Namespace root Properties → Referrals tab (not exposed via `Get-DfsnRoot`) |

---
## Validation Steps

1. **Establish the client's resolved AD site.**
   ```powershell
   nltest /dsgetsite
   ```
   Good: returns the expected physical-location site name consistently across repeated calls and across multiple clients on the same subnet.
   Bad: returns the hub/default site for a branch client, or returns different sites on repeated calls from the same machine.

2. **Confirm subnet-to-site coverage is complete.**
   ```powershell
   Get-ADReplicationSubnet -Filter * | Sort-Object Site | Format-Table Name,Site
   ```
   Good: every in-use IP range in the environment (check against DHCP scopes / IPAM) has exactly one matching subnet object.
   Bad: gaps, overlaps, or a subnet mapped to the wrong site.

3. **Map the full site-link cost graph, not just the two links involved in the ticket.**
   ```powershell
   Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded,ReplicationSchedule | Format-Table Name,Cost,SitesIncluded
   ```
   Good: the lowest-cost path from any branch to its intended preferred target is the direct/expected one.
   Bad: a lower-cost path exists through an unintended intermediate site (common when link costs were set once years ago and never revisited after new sites were added).

4. **Confirm folder target priority overrides match documented intent.**
   ```powershell
   Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" | Select-Object TargetPath,ReferralPriorityClass,ReferralPriorityRank,State
   ```
   Good: only intentionally-pinned targets (e.g., DR) show non-`SiteCost` classes; everything else is `SiteCost`/rank 0.
   Bad: an unexplained `GlobalHigh` or `GlobalLow` on a production target with no documented reason.

5. **Confirm the namespace-level referral ordering method.**
   Open DFS Management → right-click namespace root → Properties → Referrals tab.
   Good: "Lowest cost" selected (the normal/default for multi-site environments).
   Bad: "Random order" (defeats site awareness entirely) or "Exclude targets outside of the client's site" enabled without a documented reason (this drops, rather than de-prioritizes, out-of-site targets — a much harder failure mode when the local target goes down, since clients get zero fallback).

6. **Confirm client cache reflects current state after any fix.**
   ```powershell
   dfsutil /pktflush
   dfsutil /pktinfo
   ```
   Good: ordered target list now shows the expected target first.
   Bad: still wrong after flush — means the fix hasn't actually landed in AD/DFS yet (replication delay) rather than a caching problem.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Scope the symptom.** Is this one client, one site, or global? One client → check its individual subnet/site resolution and local cache first (cheapest checks). One site → check that site's subnet mapping and site-link costs. Global → check the namespace root's referral ordering method and look for a `GlobalHigh`/`GlobalLow` override affecting all targets.

**Phase 2 — Validate site topology (Layers 0–1).** Run `Get-ADReplicationSubnet` and cross-reference against actual network documentation/IPAM, not assumptions. This phase alone resolves the majority of real-world tickets — most "DFS site costing bugs" are missing subnet objects from a network team that added a VLAN without telling the AD/identity team.

**Phase 3 — Validate cost topology (Layer 2).** Map every site link and its cost. Watch specifically for asymmetry: Site A may have a fine path to Site B, but if Site C was added later with a cheap link to Site B only, clients at Site A can end up preferring Site C's targets over Site B's local ones through transitive costing.

**Phase 4 — Validate target-level overrides (Layer 3).** Audit every `ReferralPriorityClass` that isn't `SiteCost`. These are the single most common source of "it should be working per the topology, but isn't" — because they silently outrank whatever the topology says.

**Phase 5 — Validate namespace-level referral policy.** Confirm ordering method and exclusion settings at the namespace root. This is a one-time-per-namespace setting that's easy to forget was changed during a past DR exercise.

**Phase 6 — Validate propagation and caching.** Even a perfect fix takes time: AD replication of the subnet/site-link change across DCs, then the client's own cache TTL. Don't declare a fix failed inside its own propagation window.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full site-topology remediation (new branch office onboarding)</summary>

```powershell
# 1. Create the site if it doesn't exist
New-ADReplicationSite -Name "<BranchSiteName>"

# 2. Map the branch's subnet(s) to it
New-ADReplicationSubnet -Name "<CIDR>" -Site "<BranchSiteName>"

# 3. Create or confirm a site link connecting it to the hub (and any relevant branches)
New-ADReplicationSiteLink -Name "<HubToBranchLink>" -SitesIncluded "HubSite","<BranchSiteName>" -Cost 100 -ReplicationFrequencyInMinutes 180

# 4. Validate
Get-ADReplicationSubnet -Filter * | Format-Table Name,Site
Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded | Format-Table Name,Cost,SitesIncluded
```
No rollback needed for additive changes (new site/subnet/link) — these don't affect existing traffic until referenced. Validate AD replication health afterward with `repadmin /replsummary` since site/site-link objects replicate through the same channel they help manage.

</details>

<details><summary>Playbook 2 — Correcting an asymmetric or stale site-link cost graph</summary>

```powershell
# Document current costs before changing anything
Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded | Export-Csv "C:\Evidence\SiteLinkCosts-Before.csv" -NoTypeInformation

# Adjust costs so the intended direct paths are cheapest
Set-ADReplicationSiteLink -Identity "<DirectLinkName>" -Cost 100
Set-ADReplicationSiteLink -Identity "<IndirectLinkName>" -Cost 400
```
**Rollback:** re-apply values from the exported "Before" CSV with `Set-ADReplicationSiteLink`. Treat as a change-managed activity — this affects AD replication topology (KCC connection object generation) tenant-wide, not just DFS. Schedule during a low-impact window and monitor `repadmin /replsummary` for at least one full replication cycle afterward.

</details>

<details><summary>Playbook 3 — Removing a stale manual priority override</summary>

```powershell
# Identify all overrides across the namespace
Get-DfsnFolder -Path "\\<domain>\<namespace>\*" | ForEach-Object {
    Get-DfsnFolderTarget -Path $_.Path | Where-Object { $_.ReferralPriorityClass -ne "SiteCost" }
} | Select-Object Path,TargetPath,ReferralPriorityClass,ReferralPriorityRank

# Reset a specific target back to normal site-cost behavior
Set-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" -TargetPath "\\<server>\<folder>" -ReferralPriorityClass "SiteCost" -ReferralPriorityRank 0
```
**Rollback:** if the override turns out to be intentional (confirmed with the team that set it — e.g., a DR failover test still in progress), reapply the original class/rank captured in the audit output above.

</details>

<details><summary>Playbook 4 — Correcting namespace-level referral ordering policy</summary>

In DFS Management: right-click the namespace root → Properties → Referrals tab → set "Ordering method" to **Lowest cost**, and clear "Exclude targets outside of the client's site" unless there is a documented reason for it (e.g., regulatory data residency requiring hard exclusion rather than mere de-prioritization).

There is no supported PowerShell cmdlet for this specific namespace-root setting in native DFSN modules; it is stored in the namespace's AD object and is most reliably changed via the GUI or `dfsutil root export`/import for scripted bulk changes across many namespaces.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects full DFS referral/site-costing evidence for escalation or root-cause review.
#>
$evidenceDir = "C:\Evidence\DFS-SiteCosting-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null

nltest /dsgetsite > "$evidenceDir\client-site.txt"
dfsutil /pktinfo > "$evidenceDir\referral-cache.txt"
Get-ADReplicationSubnet -Filter * | Sort-Object Site | Format-Table Name,Site -AutoSize | Out-File "$evidenceDir\subnets.txt"
Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded | Format-Table Name,Cost,SitesIncluded -AutoSize | Out-File "$evidenceDir\sitelinks.txt"
Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" | Select-Object TargetPath,ReferralPriorityClass,ReferralPriorityRank,State | Export-Csv "$evidenceDir\folder-targets.csv" -NoTypeInformation

Write-Host "Evidence collected in $evidenceDir" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `nltest /dsgetsite` | Client's currently resolved AD site |
| `Get-ADReplicationSubnet -Filter *` | List all subnet→site mappings |
| `Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded` | Site link costs and membership |
| `Get-DfsnFolderTarget -Path <path>` | Targets for a folder, including priority overrides |
| `Set-DfsnFolderTarget -ReferralPriorityClass` | Change/reset a manual priority override |
| `dfsutil /pktinfo` | Dump client's cached referral list |
| `dfsutil /pktflush` | Clear client's referral cache |
| `Get-DfsnServerConfiguration -ComputerName` | Namespace server-level config |
| `New-ADReplicationSubnet` | Map a new IP range to an AD site |
| `Set-ADReplicationSiteLink -Cost` | Adjust site link cost (AD-wide impact) |
| `repadmin /replsummary` | Validate AD replication health after topology changes |

---
## 🎓 Learning Pointers
- Site costing is an **AD Sites and Services** concept that DFS merely consumes — troubleshooting almost always resolves faster by starting in `Get-ADReplicationSubnet`/`Get-ADReplicationSiteLink` rather than in DFS Management.
- The referral ordering precedence (manual override > site cost > random) means an old, forgotten `GlobalHigh` pin from a past migration or DR test can silently override a perfectly healthy topology for years.
- Site link costs are shared infrastructure between DFS referrals and AD's own replication topology (KCC) — never treat a cost change as DFS-scoped; it has tenant-wide replication implications. See Microsoft Learn: [How the Active Directory replication topology works](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/plan/planning-site-links).
- "Exclude targets outside of the client's site" is a namespace-wide policy with a hard failure mode: if the local target ever goes down, excluded clients get **no fallback at all** rather than a slower one. Use with caution, and document why if enabled.
- Client-side referral caching means fixes have a propagation delay independent of AD replication — always flush (`dfsutil /pktflush`) before concluding a fix didn't work.
- Companion hotfix runbook: `DFS-SiteCosting-B.md`. For general namespace failures unrelated to target ordering, see `Namespace-A.md`.
