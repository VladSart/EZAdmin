# AD DS Replication — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Multi-master replication between on-premises Active Directory Domain Controllers (Windows Server 2016–2022)
- Intra-site and inter-site replication topology (KCC-generated and manual)
- FSMO role placement, transfer, and seizure
- Time synchronization as a replication dependency
- SYSVOL replication is covered under `DFS/Troubleshooting/Replication/` and `DFS/Troubleshooting/FRS-Migration/` — this runbook covers the AD database (NTDS.dit) replication layer only

**Out of scope:**
- Entra Connect / hybrid sync (see `EntraID/Troubleshooting/Connect-Sync-A.md`)
- AD FS federation issues
- Cross-forest trust troubleshooting beyond basic connectivity

**Assumptions:**
- You have Domain Admin or delegated replication-management rights
- RSAT / AD DS tools are available (`repadmin`, `dcdiag`, `netdom`, `ntdsutil`)
- At least 2 DCs exist in the environment (single-DC "replication" issues are really DC health issues)

---
## How It Works

<details><summary>Full architecture — multi-master replication internals</summary>

### The Replication Model

AD DS uses **multi-master replication**: every writable DC can accept changes, and those changes propagate to every other DC. There is no single "master" copy (except for FSMO-restricted operations — see below). Replication is driven by:

1. **USN (Update Sequence Number):** Every DC maintains a local, monotonically increasing counter. Every write to any attribute increments the USN and stamps the change with it. DCs track "up-to-dateness vectors" — the highest USN they've received from every other DC — to know what they're missing.

2. **KCC (Knowledge Consistency Checker):** A process running on every DC that automatically builds and maintains the replication topology (which DC replicates with which). Runs every 15 minutes by default. Within a site, it builds a ring topology (with shortcuts if >7 DCs) for redundancy. Between sites, it uses **Site Links** and their configured cost/schedule/interval.

3. **Replication triggers:**
   - **Intra-site:** Change notification — a DC that receives a change notifies its replication partners within ~15 seconds (urgent replication for critical changes like account lockout is near-instant).
   - **Inter-site:** Scheduled, based on the Site Link's replication interval (default 180 minutes, configurable down to 15 minutes) — NOT based on change notification unless explicitly enabled.

4. **Conflict resolution:** If the same attribute is changed on two DCs before they replicate with each other, AD uses: (a) higher version number wins, (b) if tied, later timestamp wins, (c) if tied, the DC with the higher GUID wins. This is why AD is described as "loosely consistent" — for a window of time, different DCs can have different values for the same attribute.

5. **Linked-value replication (LVR):** Since Windows Server 2003, group membership changes replicate at the individual member level, not as a full attribute rewrite — this avoids a full group-membership overwrite conflict on simultaneous adds from two DCs.

### FSMO Roles (Flexible Single Master Operations)

Five roles that are NOT multi-master — only one DC in the (for forest-wide roles) forest or (for domain-wide roles) domain holds each at a time:

| Role | Scope | What breaks if unavailable |
|---|---|---|
| Schema Master | Forest | Schema extensions fail (new attributes/classes) — rare impact |
| Domain Naming Master | Forest | Cannot add/remove domains or add cross-forest trusts |
| PDC Emulator | Domain | Time sync authority, password change urgency, GPO edit locking, account lockout tracking — **highest impact role** |
| RID Master | Domain | New object creation (users/computers/groups) fails once local RID pool exhausted |
| Infrastructure Master | Domain | Cross-domain group membership references become stale (irrelevant if GC is on every DC, which is common today) |

**PDC Emulator is the domain's authoritative time source** — every other DC syncs time from the domain hierarchy which roots at the PDC Emulator (which itself should sync from an external NTP source).

### Replication Topology Types

```
Intra-site: Ring topology (KCC-built), change-notification driven, near-real-time
Inter-site: Site-Link based, scheduled, cost-weighted, can use SMTP for IP-less transport (schema/config NC only)
```

**ISTG (Inter-Site Topology Generator):** One DC per site is elected to compute the inter-site topology and pass connection objects to the KCC on relevant DCs.

</details>

---
## Dependency Stack

```
Physical/network connectivity between DC subnets
  └── DNS (AD-integrated zones, SRV records for _ldap._tcp, _kerberos._tcp)
        └── Netlogon service (locates DCs, registers SRV records, DC Locator process)
              └── Firewall: TCP/UDP 389 (LDAP), 636 (LDAPS), 3268/3269 (GC),
                  88 (Kerberos), 53 (DNS), 135 + dynamic RPC 49152-65535
                    └── W32Time (all DCs within 5 min of PDC Emulator — Kerberos hard limit)
                          └── Kerberos mutual authentication between DC pair
                                └── KCC-computed or manually configured topology (Connection objects)
                                      └── Site & Site Link configuration (cost, schedule, interval)
                                            └── Replication traffic (RPC over IP, or SMTP for inter-site NC/schema)
                                                  └── USN vectors exchanged, up-to-dateness vector updated
                                                        └── Object/attribute changes applied locally
                                                              └── (separately) SYSVOL replicates via DFSR — see DFS/ runbooks
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `repadmin /replsummary` shows consistent fails for one DC | That DC's network path, DNS, or service health is broken | `repadmin /showrepl <DC> /verbose` for error code |
| Error 1722 (RPC server unavailable) | Network/firewall blocking RPC or DC is offline | `Test-NetConnection` on port 135 + dynamic range |
| Error 8524 (DNS lookup failed for DSA) | Stale/missing DNS SRV or host record | `Resolve-DnsName _ldap._tcp.dc._msdcs.<domain>` |
| Error 8453 (Replication access denied) | Kerberos failure — usually time skew | `w32tm /query /status` on both DCs |
| Group Policy changes not appearing on some clients | SYSVOL replication lag, not AD replication — separate issue | See `DFS/Troubleshooting/Replication/Replication-A.md` |
| New user/computer object creation fails ("cannot allocate RID") | RID Master unreachable or RID pool exhausted | `netdom query fsmo`, check RID pool via `dcdiag /test:ridmanager /v` |
| Password changes take long to propagate | PDC Emulator unreachable — urgent replication of password changes routes through it | `netdom query fsmo`, verify PDC Emulator health |
| Group membership "flip-flops" between two values | Simultaneous conflicting writes on two DCs before they replicated (normal eventual-consistency behavior) | Check `repadmin /showobjmeta` for version/timestamp history on the attribute |
| A DC rejoining after long outage causes deleted objects to reappear | Lingering objects — DC was offline past tombstone lifetime | `repadmin /removelingeringobjects` (after root-causing, see Playbook 3) |
| Replication only fails between two specific sites, not others | Site Link misconfiguration (cost, schedule, or bridge) | `Get-ADReplicationSiteLink`, check schedule window |
| `dcdiag` passes but `repadmin /replsummary` shows fails | AD health is fine; issue is specific to that replication partnership (network/DNS between just those two) | Isolate to the specific DC pair, not domain-wide |

---
## Validation Steps

**Step 1 — Baseline replication health across the domain**
```powershell
repadmin /replsummary
```
Expected: `Largest Delta` for every DC under a few hours; `Fails/Total` at `0/N`.

**Step 2 — Confirm FSMO role holders and reachability**
```powershell
netdom query fsmo
foreach ($role in (netdom query fsmo | Select-String ":")) { $role }
```
Cross-check each named DC is online: `Test-Connection <RoleHolderDC>`.

**Step 3 — Full DC health validation**
```powershell
dcdiag /v /c /d /e
```
Expected: all tests pass. Pay attention to `Replications`, `Advertising`, `KnowsOfRoleHolders`, `RidManager`, `Services`, `SystemLog`.

**Step 4 — Time sync validation across all DCs**
```powershell
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
    w32tm /stripchart /computer:$dc /samples:1 /dataonly
}
```
Expected: offsets all within a few seconds of each other; PDC Emulator should be near an external stratum-1/2 source.

**Step 5 — Verify replication topology matches expectation**
```powershell
Get-ADReplicationConnection -Filter * | Select-Object Name, ReplicateFromDirectoryServer, ReplicateToDirectoryServer
Get-ADReplicationSiteLink -Filter * | Select-Object Name, Cost, ReplicationFrequencyInMinutes, SitesIncluded
```
Expected: connection objects exist for every DC pair the KCC should be maintaining; site link costs/schedules match design intent.

**Step 6 — Check up-to-dateness vectors for a specific NC**
```powershell
repadmin /showutdvec <DCName> "DC=<domain>,DC=<com>"
```
Confirms what USN each DC believes every other DC has reached — useful for spotting a DC that's silently falling behind without throwing hard errors.

**Step 7 — Verify no lingering-object risk**
```powershell
Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,DC=<domain>,DC=<com>" `
  -Properties tombstoneLifetime | Select-Object tombstoneLifetime

repadmin /showrepl * /csv | ConvertFrom-Csv |
  Select-Object "Source DSA", "Last Success Time" |
  Sort-Object "Last Success Time"
```
Flag any DC whose last successful replication predates `(Get-Date).AddDays(-[tombstoneLifetime])`.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Network & DNS Layer
1. Confirm bidirectional reachability on required ports between the affected DC pair (389, 636, 3268/3269, 88, 53, 135, dynamic RPC)
2. Confirm DNS SRV records resolve correctly from both DCs' perspective (`nslookup` from each DC, not just from a workstation)
3. Confirm no split-brain DNS (different answers for the same DC name depending on which DNS server answers)

### Phase 2 — Time & Authentication Layer
1. Validate `w32tm /query /status` on both DCs in the failing partnership
2. Confirm the domain hierarchy is intact: PDC Emulator syncing from external source, all DCs syncing from the domain hierarchy (`w32tm /query /source`)
3. If Kerberos errors appear (8453, KRB_AP_ERR_SKEW), fix time first — everything downstream depends on it

### Phase 3 — Topology Layer
1. Confirm the KCC has generated connection objects for the failing pair (or that a manual connection object exists and is correctly configured)
2. Check Site Link cost/schedule isn't inadvertently blocking replication during required windows
3. Force a topology recalculation: `repadmin /kcc <DCName>`

### Phase 4 — Data Layer
1. Force replication and capture the exact error: `repadmin /replicate <Dest> <Source> <NC-DN> /force`
2. If error persists with a data-integrity code (e.g., `8606` insufficient attributes), check for schema mismatches — usually post-upgrade or after a bad schema extension
3. Check for lingering objects if the failure mentions object-not-found on one side but present on the other

### Phase 5 — Recovery Verification
1. Re-run `repadmin /replsummary` — confirm `Fails/Total` returns to `0/N`
2. Re-run `dcdiag /v` — confirm previously failing tests now pass
3. Spot-check a recent object change (e.g., a test OU) actually replicates within expected interval
4. If SYSVOL was also affected, cross-check with `DFS/Scripts/Test-DFSHealth.ps1`

---
## Remediation Playbooks

<details><summary>Playbook 1 — Seize a FSMO role from an unrecoverable DC</summary>

**Scenario:** A DC holding a FSMO role has failed permanently (hardware loss, corruption) and will not be brought back online.

⚠️ **Seizure is a last resort.** If the DC can be recovered even temporarily, transfer the role gracefully instead (`Move-ADDirectoryServerOperationMasterRole` without `-Force`). Never bring the original role holder back online after a seizure — this creates a duplicate role holder ("USN rollback"-style corruption).

**Step 1 — Confirm the role holder is truly unreachable**
```powershell
netdom query fsmo
Test-Connection -ComputerName <FailedDC> -Count 4
```

**Step 2 — Seize the role(s) to a healthy DC**
```powershell
# Seize is done via Move-ADDirectoryServerOperationMasterRole with -Force
Move-ADDirectoryServerOperationMasterRole -Identity "<TargetDC>" `
  -OperationMasterRole SchemaMaster, RIDMaster, InfrastructureMaster, DomainNamingMaster, PDCEmulator `
  -Force
```
(Specify only the roles the failed DC actually held.)

**Step 3 — Remove metadata for the dead DC**
```powershell
# From a healthy DC, clean up the failed DC's metadata
Get-ADDomainController -Filter * | Select-Object HostName   # confirm it's gone from the list, or...
# If it still shows in AD Sites and Services / NTDS Settings, use ntdsutil metadata cleanup:
ntdsutil
# metadata cleanup > connections > connect to server <HealthyDC> > quit
# select operation target > list domains > select domain <n>
# list sites > select site <n> > list servers in site > select server <n> > quit
# remove selected server
```

**Step 4 — Verify**
```powershell
netdom query fsmo
Get-ADDomainController -Filter *
repadmin /replsummary
```

**Rollback note:** Not reversible — do not attempt to bring the seized-from DC back online. If it somehow returns, it must be forcibly demoted (`dcpromo /forceremoval`) and cleaned up before rejoining.

</details>

<details><summary>Playbook 2 — Rebuild replication topology after a site/subnet redesign</summary>

**Scenario:** Sites, subnets, or site links were changed (e.g., new branch office added) and replication isn't following the expected path.

**Step 1 — Verify site/subnet configuration**
```powershell
Get-ADReplicationSite -Filter * | Select-Object Name
Get-ADReplicationSubnet -Filter * | Select-Object Name, Site
Get-ADReplicationSiteLink -Filter * | Select-Object Name, Cost, ReplicationFrequencyInMinutes, SitesIncluded
```

**Step 2 — Confirm DCs are registered in the correct site**
```powershell
Get-ADDomainController -Filter * | Select-Object HostName, Site
```
If a DC shows the wrong site, it's usually a subnet-object misconfiguration or the DC's IP isn't covered by any defined subnet.

**Step 3 — Force KCC recalculation on all DCs**
```powershell
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) { repadmin /kcc $dc }
```

**Step 4 — Force a full sync to validate the new topology**
```powershell
repadmin /syncall /AdeP
```

**Rollback note:** Safe — topology recalculation doesn't touch object data, only connection objects.

</details>

<details><summary>Playbook 3 — Remove lingering objects after a stale DC rejoin</summary>

**Scenario:** A DC was offline beyond tombstone lifetime and either was allowed back online (mistake) or objects deleted elsewhere are reappearing.

**Step 1 — Confirm lingering objects exist**
```powershell
# Enable strict replication consistency temporarily to detect (default is enabled on 2003+ DCs)
repadmin /options <DCName> +STRICT_REPL_CONSISTENCY

# Attempt replication — if lingering objects exist, replication will now fail with event 1988 instead of silently resurrecting them
repadmin /replicate <DestDC> <SourceDC> "DC=<domain>,DC=<com>"
```
Check Event Viewer (Directory Service log) for **Event ID 1988** — it names the specific lingering object.

**Step 2 — Remove the lingering object from the affected DC**
```powershell
repadmin /removelingeringobjects <SuspectDC> <ReferenceDC-GUID> "DC=<domain>,DC=<com>" /advisory_mode
# Review output, then run for real (remove /advisory_mode):
repadmin /removelingeringobjects <SuspectDC> <ReferenceDC-GUID> "DC=<domain>,DC=<com>"
```

**Step 3 — Repeat for every NC (schema, configuration, domain) as needed, on every DC that has the lingering copy**

**Rollback note:** This is a destructive removal of stale data — always run with `/advisory_mode` first to see what would be removed before committing.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  AD DS Replication Evidence Collector
.NOTES     Run from any Domain Controller with Domain Admin rights
#>

$reportPath = "C:\Temp\ADReplEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

"=== Replication Summary ===" | Out-File "$reportPath\01_ReplSummary.txt"
repadmin /replsummary | Out-File "$reportPath\01_ReplSummary.txt" -Append

"=== Detailed Replication Status (all DCs) ===" | Out-File "$reportPath\02_ShowRepl.txt"
repadmin /showrepl * /verbose /all | Out-File "$reportPath\02_ShowRepl.txt" -Append

"=== FSMO Role Holders ===" | Out-File "$reportPath\03_FSMO.txt"
netdom query fsmo | Out-File "$reportPath\03_FSMO.txt" -Append

"=== DCDiag Full ===" | Out-File "$reportPath\04_DCDiag.txt"
dcdiag /v /c /d /e | Out-File "$reportPath\04_DCDiag.txt" -Append

"=== Sites, Subnets, Site Links ===" | Out-File "$reportPath\05_Topology.txt"
Get-ADReplicationSite -Filter * | Format-List | Out-File "$reportPath\05_Topology.txt" -Append
Get-ADReplicationSubnet -Filter * | Format-List | Out-File "$reportPath\05_Topology.txt" -Append
Get-ADReplicationSiteLink -Filter * | Format-List | Out-File "$reportPath\05_Topology.txt" -Append

"=== Time Sync (per DC) ===" | Out-File "$reportPath\06_TimeSync.txt"
$dcs = (Get-ADDomainController -Filter *).HostName
foreach ($dc in $dcs) {
    "--- $dc ---" | Out-File "$reportPath\06_TimeSync.txt" -Append
    w32tm /stripchart /computer:$dc /samples:1 /dataonly | Out-File "$reportPath\06_TimeSync.txt" -Append
}

"=== Tombstone Lifetime ===" | Out-File "$reportPath\07_Tombstone.txt"
$domainDN = (Get-ADDomain).DistinguishedName
Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN" `
  -Properties tombstoneLifetime | Format-List | Out-File "$reportPath\07_Tombstone.txt" -Append

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Replication summary | `repadmin /replsummary` |
| Detailed replication status | `repadmin /showrepl * /verbose /all` |
| Force replication | `repadmin /replicate <Dest> <Source> "<NC-DN>" /force` |
| Force sync all | `repadmin /syncall /AdeP` |
| Force KCC recalculation | `repadmin /kcc <DCName>` |
| Show up-to-dateness vector | `repadmin /showutdvec <DC> "<NC-DN>"` |
| Show object metadata/version history | `repadmin /showobjmeta <DC> "<Object-DN>"` |
| Remove lingering objects (advisory) | `repadmin /removelingeringobjects <DC> <RefDC-GUID> "<NC-DN>" /advisory_mode` |
| Full DC health check | `dcdiag /v /c /d /e` |
| Query FSMO holders | `netdom query fsmo` |
| Transfer FSMO role | `Move-ADDirectoryServerOperationMasterRole -Identity <DC> -OperationMasterRole <Role>` |
| Seize FSMO role | `Move-ADDirectoryServerOperationMasterRole -Identity <DC> -OperationMasterRole <Role> -Force` |
| Check time sync status | `w32tm /query /status` |
| Force time resync | `w32tm /resync /rediscover` |
| List DCs and their site | `Get-ADDomainController -Filter * \| Select HostName, Site` |
| List site links | `Get-ADReplicationSiteLink -Filter *` |
| List replication connections | `Get-ADReplicationConnection -Filter *` |

---
## 🎓 Learning Pointers

- **Multi-master replication means "eventually consistent," not "instantly consistent."** Seeing two DCs briefly disagree on an attribute value is normal and expected — the conflict-resolution algorithm (version number → timestamp → GUID) will settle it once they replicate. Don't chase this as a bug; chase it only if it never converges. [AD replication concepts](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/get-started/replication/active-directory-replication-concepts)
- **The PDC Emulator is the single highest-impact FSMO role.** It anchors the domain's time hierarchy and handles urgent password-change replication and account-lockout tracking. If only one FSMO role holder's health you can check today, make it this one. [FSMO roles explained](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/fsmo-roles)
- **Time skew failures masquerade as replication or authentication bugs.** Because Kerberos hard-fails past 5 minutes of skew, and Kerberos underlies RPC authentication between DCs, a clock drift on a single VM can produce error codes that look like a network or permissions problem. Check `w32tm` early, not last.
- **Tombstone lifetime turns "bring the old DC back" into a one-way decision.** Past that window (default 180 days, verify actual value — it changed from 60 to 180 days in Server 2003 SP1+), a DC cannot safely rejoin without risking lingering objects. Budget for a rebuild, not a recovery, once that threshold is crossed. [Lingering objects](https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/lingering-objects-domain-services)
- **Strict replication consistency is your safety net — verify it's on.** `repadmin /options <DC>` should show `STRICT_REPL_CONSISTENCY` enabled (default since Server 2003 DCs joined post-SP1). Without it, lingering objects replicate silently instead of throwing Event 1988, making them far harder to detect.
- **AD replication and SYSVOL replication are two separate systems that get confused constantly.** A "GPO not applying" ticket is very often a SYSVOL/DFSR issue, not an AD DS replication issue — cross-reference `DFS/Troubleshooting/Replication/Replication-A.md` before assuming this runbook covers it.
