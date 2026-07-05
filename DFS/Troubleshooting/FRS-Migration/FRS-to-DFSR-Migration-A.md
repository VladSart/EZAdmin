# FRS-to-DFSR SYSVOL Migration — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index (with jump links)
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
- Migrating SYSVOL replication from the legacy File Replication Service (FRS) to DFS Replication (DFSR)
- Domains running mixed FRS/DFSR during transition, and the four-state migration model
- Windows Server 2008 R2 through 2022 domain controllers

**Out of scope:**
- General DFSR troubleshooting once fully migrated (see `DFS/Troubleshooting/Replication/Replication-A.md`)
- DFS Namespace configuration (unrelated to SYSVOL)
- Third-party AD migration tools

**Assumes:**
- Domain functional level 2008 or higher (required for DFSR SYSVOL support)
- Enterprise Admin or Domain Admin rights (global state changes require elevated permissions)
- All DCs are reachable, patched, and AD replication is otherwise healthy before starting

---

## How It Works

<details><summary>Full architecture — the FRS→DFSR SYSVOL migration state machine</summary>

### Why this migration exists

FRS (File Replication Service) was the original SYSVOL replication engine for Windows 2000/2003-era AD. It is single-threaded, has no built-in backlog reporting, and was deprecated starting with Windows Server 2008 R2 in favor of DFSR, which uses RDC (Remote Differential Compression) for efficient, resumable, and monitorable replication. Microsoft has not shipped bug fixes for FRS in over a decade. Any domain still relying on it for SYSVOL is running unsupported infrastructure.

### The four migration states

Migration is controlled by a single domain-wide attribute plus a per-DC confirmation mechanism:

```
State 0 — START
   Both FRS and DFSR exist but only FRS is authoritative.
   DFSR SYSVOL replica set is created but not yet serving clients.
        │
        ▼
State 1 — PREPARED
   DFSR performs an initial sync of SYSVOL content from FRS into a
   parallel DFSR-managed folder (SYSVOL_DFSR). Clients still use FRS SYSVOL.
   This is the safest state to sit in for validation before cutover.
        │
        ▼
State 2 — REDIRECTED
   Clients are redirected to consume SYSVOL from the DFSR-managed
   folder. FRS keeps replicating in the background as a fallback
   only — NOT actively serving clients anymore.
        │
        ▼
State 3 — ELIMINATED  (IRREVERSIBLE)
   FRS SYSVOL replica set and its data are permanently deleted from
   every DC. DFSR is now the sole source of truth. No path back to
   FRS exists after this point.
```

### Why per-DC state matters more than global state

The domain-wide "global state" is a *target* — it's what an admin sets via `dfsrmig /setglobalstate N`. Each DC must then independently detect the change (via AD replication), perform its own local transition, and report success back into AD (`msDFSR-Options` attribute on the DC's computer object). `dfsrmig /getglobalstate` only tells you what was *requested*. `dfsrmig /getmigrationstate` tells you what has actually *happened* on each DC. A "stuck" migration is always a mismatch between these two views.

### Why AD replication is the hidden dependency

Because the entire state machine is encoded in AD attributes rather than a separate coordination protocol, DFSR migration cannot progress faster than AD convergence. In multi-site domains with slow inter-site links, this can mean waiting hours between state changes — this is expected, not a fault.

</details>

---

## Dependency Stack

```
┌───────────────────────────────────────────┐
│   Domain Controllers (clients of SYSVOL)   │  ← GPO processing, logon scripts
├───────────────────────────────────────────┤
│   SYSVOL share (\\domain\SYSVOL)           │  ← Backed by FRS OR DFSR depending on state
├───────────────────────────────────────────┤
│   DFSR SYSVOL Replica Set                  │  ← "Domain System Volume" replication group
│   ("SYSVOL_DFSR" local folder pre-cutover) │
├───────────────────────────────────────────┤
│   FRS SYSVOL Replica Set (legacy)          │  ← Present until state 3, then deleted
├───────────────────────────────────────────┤
│   Migration State Machine                 │  ← msDFSR-Options / msDFSR-Flags AD attributes
├───────────────────────────────────────────┤
│   Active Directory Replication             │  ← Must converge before state advances domain-wide
├───────────────────────────────────────────┤
│   dfsrmig.exe / ntfrsutl.exe               │  ← Admin tooling to read/set state
└───────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `/getmigrationstate` never shows a DC as "succeeded" | DC unreachable, DFSR service stopped, or AD replication hasn't reached it | `Get-Service DFSR -ComputerName <dc>`, `repadmin /showrepl <dc>` |
| Migration hangs indefinitely at Redirected | Orphaned/phantom DC object never cleaned up after decommission | `Get-ADDomainController -Filter *` vs actual live server list |
| GPOs stop applying domain-wide right after a state change | A DC's SYSVOL share dropped during transition (temporary is normal, prolonged is not) | `net share` on affected DC, `dcdiag /test:sysvolcheck` |
| `/setglobalstate 3` command fails immediately | Not run with sufficient (Enterprise Admin) rights, or a prerequisite DC hasn't confirmed state 2 | Re-run `/getmigrationstate`, check current logged-in account rights |
| Some DCs show old FRS event IDs after migration reported complete | Migration state advanced globally before that DC actually finished converging | Re-check `/getmigrationstate` per-DC, don't trust `/getglobalstate` alone |
| Users at a specific site experience intermittent logon script failures during migration | Expected transient behavior while that site's DC is mid-transition — should resolve once state settles | Confirm via Event ID 8014 (start) → 8004 (complete) on that site's DC |
| FRS event log shows replication continuing after "Eliminated" reported | Stale monitoring data or a DC that was never actually part of migration scope | Re-run `dfsrmig /getmigrationstate`, confirm DC is domain-joined and current |

---

## Validation Steps

**1. Confirm domain functional level supports DFSR SYSVOL**
```powershell
Get-ADDomain | Select-Object DomainMode
```
Expected: `Windows2008Domain` or higher. Below this, DFSR SYSVOL migration is not supported — raise domain functional level first (separate, higher-risk change).

**2. Enumerate all DCs and confirm reachability before starting**
```powershell
Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, OperatingSystem |
  ForEach-Object { [PSCustomObject]@{ Name=$_.Name; Reachable=(Test-Connection $_.IPv4Address -Count 1 -Quiet) } }
```
Expected: All DCs reachable. Any unreachable DC must be resolved or decommissioned before migration proceeds.

**3. Check current global and per-DC migration state**
```powershell
dfsrmig /getglobalstate
dfsrmig /getmigrationstate
```
Expected before starting: Global state 0 (Start), all DCs healthy.

**4. Validate AD replication is fully converged**
```powershell
repadmin /replsummary
```
Expected: 0% failures across the board. Do not begin or advance migration with outstanding replication failures.

**5. Confirm no orphaned DC objects exist**
```powershell
Get-ADDomainController -Filter * | Select-Object Name
# Cross-reference against known-live server inventory — anything in AD but not live is a blocker
```

**6. After each state change, wait for full convergence before proceeding**
```powershell
# Poll every 5 minutes until all DCs show "succeeded" for the new state
dfsrmig /getmigrationstate
```
Expected: 100% of DCs listed as succeeded before issuing the next `/setglobalstate` command.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Pre-migration health check
1. Run all Validation Steps above
2. Resolve any AD replication failures first — do not proceed with a migration on an unhealthy domain
3. Document current FSMO role holders: `netdom query fsmo` — the PDC emulator plays a coordination role during migration

### Phase 2 — State 0 → 1 (Start → Prepared)
1. `dfsrmig /setglobalstate 1`
2. Poll `dfsrmig /getmigrationstate` every 5–10 minutes
3. Each DC creates a local `SYSVOL_DFSR` folder and performs initial sync from FRS — this can take time proportional to SYSVOL size and inter-site bandwidth
4. Watch for Event ID 8004 (per-DC migration triggered) in the DFS Replication event log on each DC

### Phase 3 — State 1 → 2 (Prepared → Redirected)
1. Confirm ALL DCs succeeded at state 1 first — this is the most commonly skipped check
2. `dfsrmig /setglobalstate 2`
3. Clients begin reading SYSVOL from the DFSR-managed path; FRS continues running as a fallback
4. Validate GPO application is unaffected: `gpupdate /force` on a handful of test clients across different sites
5. This is a good state to "soak" for a few days in larger environments before eliminating FRS

### Phase 4 — State 2 → 3 (Redirected → Eliminated) — IRREVERSIBLE
1. Re-run full validation steps — this is the point of no return
2. Confirm zero orphaned DC objects
3. Confirm zero outstanding AD replication failures
4. `dfsrmig /setglobalstate 3`
5. FRS SYSVOL replica sets are deleted from every DC — the `NtFrs` service can now be disabled
6. Monitor Event ID 8020 (elimination complete) on each DC

### Phase 5 — Post-migration cleanup
1. Disable and eventually remove the FRS service where no longer needed: `Set-Service NtFrs -StartupType Disabled`
2. Remove any lingering references to FRS in monitoring/alerting tooling
3. Update documentation and change records to reflect DFSR as SYSVOL's sole replication mechanism

---

## Remediation Playbooks

<details><summary>Playbook 1 — Recover a DC stuck at a migration state due to AD replication lag</summary>

Use when: One or more DCs never appear in the "succeeded" list for the current state, and AD replication shows failures involving that DC.

```powershell
# Step 1: Diagnose the specific replication failure
repadmin /showrepl <stuckDC> /csv | ConvertFrom-Csv

# Step 2: Force replication from a healthy partner
repadmin /replicate <stuckDC> <healthyPartnerDC> "<DomainNamingContextDN>"

# Step 3: Re-poll migration state
dfsrmig /getmigrationstate
```

**Rollback:** N/A — this is a corrective action for AD replication, not a destructive DFSR operation.

</details>

<details><summary>Playbook 2 — Remove an orphaned DC object blocking global state advancement</summary>

Use when: A decommissioned DC is still present in `Get-ADDomainController -Filter *` and migration will not proceed past its current state.

```powershell
# Step 1: Confirm the DC is genuinely gone (not just temporarily offline)
Test-Connection <suspectDC> -Count 2 -Quiet

# Step 2: Use ntdsutil to perform metadata cleanup (run from a healthy DC)
# This removes the phantom DC object from AD, DNS, and FRS/DFSR member lists
ntdsutil "metadata cleanup" "remove selected server <suspectDC>" quit quit

# Step 3: Re-check migration state
dfsrmig /getmigrationstate
```

**Rollback:** If the DC was actually still live and this was done in error, the server must be re-promoted from scratch (`dcpromo`/`Install-ADDSDomainController`) — there is no in-place undo for metadata cleanup.

> **Reference:** https://learn.microsoft.com/en-us/troubleshoot/windows-server/identity/remove-metadata-active-directory-domain-controller

</details>

<details><summary>Playbook 3 — Roll back from Prepared or Redirected (state 1 or 2) to Start</summary>

Use when: A serious issue is discovered before reaching Eliminated and the migration needs to be paused/reverted.

```powershell
# Confirm current state first
dfsrmig /getglobalstate

# Roll back one step at a time — do not skip states
dfsrmig /setglobalstate 0

# Monitor all DCs return to consistent Start state
dfsrmig /getmigrationstate
```

**Rollback of rollback:** None needed — this IS the rollback path. Only usable while state < 3.

</details>

<details><summary>Playbook 4 — Post-Eliminated FRS remnants cleanup</summary>

Use when: Migration reports Eliminated (state 3) domain-wide but `NtFrs` service and old FRS folders remain on disk.

```powershell
foreach ($dc in (Get-ADDomainController -Filter * | Select -Expand HostName)) {
    Invoke-Command -ComputerName $dc -ScriptBlock {
        Set-Service NtFrs -StartupType Disabled
        Stop-Service NtFrs -Force -ErrorAction SilentlyContinue
    }
}
# Manually archive (do not delete outright) old FRS SYSVOL staging folders before removing,
# in case of audit/rollback questions post-migration:
# %SystemRoot%\SYSVOL\domain (old FRS path) vs SYSVOL_DFSR (new active path)
```

**Rollback:** Re-enabling `NtFrs` does not restore FRS SYSVOL replication — the replica set itself was deleted at state 3. This step is cleanup-only, not reversible in a meaningful way.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect full FRS-to-DFSR migration evidence for escalation or change record
#>
param(
    [string]$OutputPath = "C:\Temp\SYSVOL-Migration-Evidence"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"

dfsrmig /getglobalstate | Out-File "$OutputPath\global-state-$ts.txt"
dfsrmig /getmigrationstate | Out-File "$OutputPath\migration-state-$ts.txt"

Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, OperatingSystem |
    Export-Csv "$OutputPath\dc-inventory-$ts.csv" -NoTypeInformation

repadmin /replsummary | Out-File "$OutputPath\repl-summary-$ts.txt"

foreach ($dc in (Get-ADDomainController -Filter * | Select-Object -Expand HostName)) {
    try {
        Get-WinEvent -ComputerName $dc -LogName "DFS Replication" -MaxEvents 100 -ErrorAction Stop |
            Where-Object { $_.Id -in 8004,8014,8016,8018,8020 } |
            Export-Csv "$OutputPath\dfsr-migration-events-$dc-$ts.csv" -NoTypeInformation
    } catch {
        "Could not reach $dc : $_" | Out-File "$OutputPath\errors-$ts.txt" -Append
    }
}

Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath-$ts.zip"
Write-Host "Evidence pack: $OutputPath-$ts.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get domain-wide target migration state | `dfsrmig /getglobalstate` |
| Get actual per-DC migration state | `dfsrmig /getmigrationstate` |
| Advance to Prepared | `dfsrmig /setglobalstate 1` |
| Advance to Redirected | `dfsrmig /setglobalstate 2` |
| Advance to Eliminated (irreversible) | `dfsrmig /setglobalstate 3` |
| Roll back one state | `dfsrmig /setglobalstate <lowerNumber>` |
| Check SYSVOL/NETLOGON share status | `net share` |
| Test AD replication health | `repadmin /replsummary` |
| Force replication from a partner | `repadmin /replicate <dc> <partner> "<namingContext>"` |
| List all DCs | `Get-ADDomainController -Filter *` |
| Remove orphaned DC metadata | `ntdsutil "metadata cleanup" "remove selected server <dc>" quit quit` |
| Check FSMO role holders | `netdom query fsmo` |
| Disable legacy FRS service post-migration | `Set-Service NtFrs -StartupType Disabled` |
| DC-level SYSVOL health check | `dcdiag /test:sysvolcheck /test:netlogons` |

---

## 🎓 Learning Pointers

- **The migration state machine lives inside AD itself**, not a separate coordination service — `msDFSR-Options` on each DC's computer object. This is why AD replication health is the single biggest predictor of migration success. Treat any migration attempt on a domain with existing replication issues as high-risk. [MS Docs: SYSVOL Migration Series](https://learn.microsoft.com/en-us/windows-server/storage/dfs-replication/migrate-sysvol-to-dfsr)
- **State 3 (Eliminated) is a one-way door.** Unlike most AD changes, there is no supported rollback once FRS SYSVOL replica sets are deleted. Budget for a soak period at Redirected (state 2) of at least several days in production before eliminating.
- **Orphaned DC objects are the classic cause of migrations that hang forever.** If a company decommissioned DCs over the years without proper `ntdsutil` metadata cleanup, `dfsrmig` will wait indefinitely for confirmation from a server that no longer exists. Always audit `Get-ADDomainController -Filter *` against a live inventory before starting.
- **FRS is not just "old" — it is functionally frozen.** Microsoft has shipped no new FRS fixes since Windows Server 2008 R2 introduced DFSR SYSVOL support. Any bug encountered in FRS today has no vendor remediation path other than migrating off it.
- **This is a domain-wide, coordinated change — never partial.** Unlike most DFSR replication group changes, SYSVOL migration state applies to the whole domain simultaneously; you cannot migrate one DC's SYSVOL while leaving others on FRS indefinitely (state 1/2 is a temporary parallel-running phase, not a permanent split).
- **Community resource:** Microsoft's own "FRS2DFSR" migration guidance and the classic TechNet blog series "Deploying the Software Update Services Guide" era discussions on SYSVOL are dated but still the most detailed walkthroughs of the state machine's internals — search "SYSVOL migration state 2 stuck" on Microsoft Q&A for current real-world cases.
