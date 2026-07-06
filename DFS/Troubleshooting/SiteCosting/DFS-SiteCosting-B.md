# DFS Referral Ordering & Site Costing — Hotfix Runbook (Mode B: Ops)
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

Run these from an affected client or the namespace server. Goal: confirm the client is being referred to the *wrong* (usually slower/remote) folder target.

```powershell
# 1. What target is the client actually using right now?
Get-SmbConnection | Where-Object { $_.ServerName -like "*fileserver*" } | Format-Table ServerName,ShareName,Dialect

# 2. Force a fresh referral and see the full ordered list DFS returned
dfsutil /pktflush
dfsutil /spcinfo
Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" | Format-Table Path,TargetPath,State

# 3. What AD site is this client in, and what site is each target server in?
nltest /dsgetsite
Get-ADComputer -Identity $env:COMPUTERNAME -Properties * | Select-Object Name, @{n='Site';e={(Get-ADDomainControllerSiteLink -ErrorAction SilentlyContinue)}}
nltest /dsgetsitecov:<fileserver1>
nltest /dsgetsitecov:<fileserver2>

# 4. What's the configured site link cost between the client's site and each target's site?
Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded | Format-Table Name,Cost,SitesIncluded

# 5. Is the namespace configured for cost-based (lowest-cost) or random/exclude-based ordering?
Get-DfsnServerConfiguration -ComputerName <namespaceServer>
```

| Result | Interpretation |
|---|---|
| Client's active connection points to a target in a **different site than the client** while a same-site target exists and is online | Referral ordering is wrong — go to Fix 1 or Fix 2 |
| `nltest /dsgetsite` returns a site with **no subnet mapping** for that client's IP range | Client isn't mapped to any AD site — go to Fix 3 |
| Site link cost between client's site and the "wrong" target's site is **lower** than to the "right" target's site | Site costing itself is misconfigured (not a DFS bug) — go to Fix 4 |
| `Get-DfsnServerConfiguration` shows `LdapTimeoutInSec` unusually low or `SiteCostedReferrals` disabled | DFS server-level override is forcing random ordering — go to Fix 5 |
| Folder target's **Referral priority** is manually set to "First among all targets" on the wrong target | Manual priority override beats site costing — go to Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for correct referral ordering</summary>

```
Client IP address
      │
      ▼
AD Subnet object maps IP → AD Site   ◄── missing/wrong subnet = client "homeless", falls back to random or default site
      │
      ▼
AD Site Link cost between client's Site and each target server's Site
      │
      ▼
Namespace server queries AD for site-cost-ordered target list
      │
      ▼
DFSN referral response ordered by:
   1. Manual "Referral priority" override on folder target (if set) — wins over everything
   2. Same site as client (cost 0) — always first if not overridden
   3. Lowest site-link cost, ascending
   4. Random order among equal-cost targets (unless "Exclude targets outside client's site" is set)
      │
      ▼
Client caches referral (default TTL 1800 sec via DfsDcTimeout / TargetListTTL)
      │
      ▼
Client connects to FIRST target in cached list
```

Break any layer above the referral response and the client silently ends up talking to a WAN-distant file server with full-speed-looking SMB but terrible latency — this is why it presents as "the file server is slow" rather than "DFS is broken."

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the client's AD site assignment is correct.**
   ```powershell
   nltest /dsgetsite
   ```
   Expected: the site name matching the client's physical location. If it returns the **hub/default site** instead of a branch site, the client's subnet was never added to AD Sites and Services, or was added to the wrong site.

2. **Confirm the subnet-to-site mapping exists in AD.**
   ```powershell
   Get-ADReplicationSubnet -Filter * | Format-Table Name,Site
   ```
   Expected: a subnet entry covering the client's IP range, mapped to the correct site. If missing, this is the root cause — not a DFS setting at all.

3. **Confirm site link cost is lower to the intended target's site.**
   ```powershell
   Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded | Format-Table Name,Cost,SitesIncluded
   ```
   Expected: the link between client-site and preferred-target-site has the lowest cost of any path. Lower cost number = preferred. A common misconfig: two site links both include the hub site but the branch-to-branch link is missing, forcing all cross-branch traffic through a higher-cost hub path that happens to score lower than the "obvious" direct link.

4. **Confirm the namespace isn't overriding costing with a manual priority.**
   ```powershell
   Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" | Select-Object TargetPath, ReferralPriorityClass, ReferralPriorityRank
   ```
   Expected: `ReferralPriorityClass` = `SiteCost` (or `GlobalHigh`/`GlobalLow` only if intentionally set). If a target shows `SiteCost` with `ReferralPriorityRank 0` on the WRONG target, someone manually pinned it.

5. **Confirm the client isn't serving a stale cached referral.**
   ```powershell
   dfsutil /pktinfo
   ```
   Expected: TargetList reflects current AD site topology. If stale, flush with `dfsutil /pktflush` and re-test before concluding it's a config issue.

---
## Common Fix Paths

<details><summary>Fix 1 — Client has no subnet-to-site mapping (most common root cause)</summary>

```powershell
# On a DC, find the client's IP range and confirm no subnet object covers it
Get-ADReplicationSubnet -Filter * | Format-Table Name,Site

# Create the missing subnet object, mapping it to the correct site
New-ADReplicationSubnet -Name "<clientSubnetCIDR e.g. 10.20.5.0/24>" -Site "<CorrectSiteName>"
```
No rollback risk — this only adds a mapping AD didn't have. Client will pick up the correct site on next `nltest`/DC contact (can force with `nltest /dsgetsite` immediately after; full effect within one Netlogon site-discovery cycle, ~5 min).

</details>

<details><summary>Fix 2 — Referral cache is stale on the client</summary>

```powershell
dfsutil /pktflush
gpupdate /force
```
Safe, no rollback needed. If this alone fixes it, the underlying AD/DFS config was already correct — the client just needed a kick.

</details>

<details><summary>Fix 3 — Client site has no subnet object at all (falls back to default/first site)</summary>

Same remediation as Fix 1. Confirm with:
```powershell
nltest /dsgetsite
```
If it silently returns the site of the first DC that answered rather than erroring, that's the fallback behavior — it looks "fine" in casual testing but is wrong for that client's actual location.

</details>

<details><summary>Fix 4 — Site link cost is genuinely misconfigured</summary>

```powershell
# View current costs
Get-ADReplicationSiteLink -Filter * -Properties Cost,SitesIncluded

# Lower the cost on the correct/preferred link (lower number = preferred path)
Set-ADReplicationSiteLink -Identity "<SiteLinkName>" -Cost 100

# Raise cost on a link that should NOT be preferred
Set-ADReplicationSiteLink -Identity "<OtherSiteLinkName>" -Cost 500
```
**Rollback:** record the original `Cost` value before changing (`Get-ADReplicationSiteLink` output) — site link costs also affect AD replication topology and KCC-generated connection objects, not just DFS. Changing them can shift replication paths tenant-wide. Do this with a change record, not ad hoc, and validate AD replication (`repadmin /replsummary`) after the change.

</details>

<details><summary>Fix 5 — Namespace server config disabled cost-based referrals</summary>

```powershell
Get-DfsnServerConfiguration -ComputerName <namespaceServer>

# Re-enable site costing behavior (defaults shown; adjust only what's wrong)
Set-DfsnServerConfiguration -ComputerName <namespaceServer> -UseFqdn $true
```
There is no single "SiteCostedReferrals off" switch in modern DFSN — if referrals appear random, check the namespace's **Referral Ordering Method** on the namespace object itself (Namespace properties → Referrals tab in DFS Management console, or `Get-DfsnRoot` doesn't expose this — must use the GUI or `dfsutil root export`). Confirm it is set to "Lowest cost" not "Random order" or "Exclude targets outside of the client's site."

</details>

<details><summary>Fix 6 — Folder target has a manual priority override pinning the wrong server</summary>

```powershell
# Check current overrides
Get-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" | Select-Object TargetPath, ReferralPriorityClass, ReferralPriorityRank

# Reset the wrong target back to site-cost-based ordering (removes the override)
Set-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" -TargetPath "\\<wrongServer>\<folder>" -ReferralPriorityClass "SiteCost" -ReferralPriorityRank 0
```
**Rollback:** if the override was intentional (e.g., a DR target that should never be preferred), restore it explicitly:
```powershell
Set-DfsnFolderTarget -Path "\\<domain>\<namespace>\<folder>" -TargetPath "\\<targetServer>\<folder>" -ReferralPriorityClass "GlobalLow"
```

</details>

---
## Escalation Evidence

```
DFS Site-Costing Escalation — <date>
Namespace path affected: \\<domain>\<namespace>\<folder>
Client(s) affected: <hostname(s) / site>
Client's AD site (nltest /dsgetsite): <result>
Subnet object exists for client IP range? (Get-ADReplicationSubnet): <yes/no + subnet>
Site link cost, client-site → intended target site: <cost>
Site link cost, client-site → observed (wrong) target site: <cost>
ReferralPriorityClass on wrong target (Get-DfsnFolderTarget): <value>
dfsutil /pktinfo output (attach or summarize target order): <attached>
Fix attempted: <Fix # from above>
Result: <resolved / still routing to wrong target / needs AD site topology change>
Escalating because: <e.g. site link cost change affects broader AD replication topology, needs infra approval>
```

---
## 🎓 Learning Pointers
- Referral ordering is computed from **AD Sites and Services**, not from anything inside DFS Management — most "DFS is misconfigured" tickets are actually AD site-topology gaps. Start there before touching namespace settings.
- `nltest /dsgetsite` tells you what site a machine *thinks* it's in — always verify against `Get-ADReplicationSubnet` rather than trusting the client's assumption.
- Manual referral priority overrides (`ReferralPriorityClass`) are sticky and easy to forget — audit them whenever a "why is this user hitting the DR server" ticket comes in.
- Site link cost changes affect AD replication topology tenant-wide, not just DFS referrals — treat cost changes as a change-managed AD activity, not a quick DFS tweak. See Microsoft Learn: [Configuring Site Link cost](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/plan/planning-site-links).
- Client-side referral caching (`dfsutil /pktinfo`, default TTL from `TargetListTTL`) means a fix can be "correct" in AD for several minutes before a given client actually observes it — don't declare a fix failed based on an unflushed cache.
- Deep dive on the full referral algorithm and priority precedence order: `DFS-SiteCosting-A.md`.
