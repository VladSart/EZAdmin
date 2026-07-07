# Group Policy Processing & Replication — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This document covers **Group Policy Object (GPO) client-side processing** — how a domain-joined Windows machine discovers, filters, retrieves, and applies GPOs at boot/logon and on the background refresh cycle — and **GPO replication**, i.e. how a GPO's two halves (the AD-stored Group Policy Container, and the SYSVOL-stored Group Policy Template) stay in sync across domain controllers.

It assumes:
- On-premises AD DS (not Intune/CSP-based policy — see `Intune/Troubleshooting/GP-to-CSP-B.md` for that migration path)
- SYSVOL is DFSR-replicated (legacy FRS is out of scope — see `DFS/Troubleshooting/FRS-Migration/`)
- The AD DS replication layer carrying the GPC object itself is healthy (see `ActiveDirectory/Troubleshooting/Replication/`) — this doc assumes that layer works and focuses on the GPO-specific mechanics built on top of it

Not covered: Group Policy Preferences item-level targeting logic in depth (brief mention only), Intune-native configuration profiles, third-party GPO management tools (SDM/Quest GPOADmin etc.), and GPO backup/restore mechanics (see `ActiveDirectory/Troubleshooting/BackupRestore/` for the AD object side; GPO-specific backup uses `Backup-GPO`/`Restore-GPO` which are out of scope here).

---
## How It Works

<details><summary>Full architecture</summary>

**The two-part GPO.** Every GPO is split across two storage locations that must agree:

- **Group Policy Container (GPC)** — an AD object under `CN=Policies,CN=System,DC=<domain>`. Holds the GPO's GUID, links, WMI filter reference, security descriptor (which doubles as the security-filtering ACL), and a version number (`versionNumber` attribute).
- **Group Policy Template (GPT)** — a folder on SYSVOL at `\\<domain>\SysVol\<domain>\Policies\{GUID}\`. Holds the actual settings payload (`Registry.pol` for Administrative Templates, scripts, GPP XML, security templates, etc.) and a `gpt.ini` file whose `Version=` line must match the GPC's `versionNumber`.

The GPC replicates via normal AD DS multi-master replication (see `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md`). The GPT replicates via DFSR, which replicates the SYSVOL share as a whole (see `DFS/Troubleshooting/Replication/`). These are **two independent replication systems** with independent topologies, schedules, and failure modes — a GPO can be "synced" in AD but stale in SYSVOL, or vice versa, and Windows will surface this as an explicit "AD / SYSVOL Version Mismatch" condition in `gpresult /h`.

**The client-side processing pipeline**, in order, on every boot (computer policy) and logon (user policy), plus background refresh (default every 90-120 min with randomized offset):

1. **Network availability check.** The Group Policy Client service (`gpsvc`) waits for network stack availability signaled by NLA (Network Location Awareness). Fast Boot / Fast Logon Optimization means this frequently does NOT happen before the desktop appears — policy applies as an asynchronous "background" pass instead, which matters because some CSEs (Software Installation, Folder Redirection) refuse to run in background mode by design.
2. **Domain Controller discovery (DC Locator).** DNS SRV record lookup finds candidate DCs; AD Sites and Services subnet-to-site mapping determines which DC is "closest." A misconfigured subnet object routes clients to a distant DC — this alone can trigger slow-link detection even on a fast local network.
3. **Slow-link detection.** The client measures round-trip latency/bandwidth to the chosen DC. Below the configured threshold (default effective ~500 Kbps via the modern ICMP-based measurement, configurable via "Configure Group Policy Slow Link Detection"), some CSEs skip processing entirely per-CSE policy (each CSE has its own "Allow processing across a slow network connection" toggle).
4. **GPO enumeration (LDAP query against AD).** The client queries AD for GPOs linked at its site, domain, and OU chain (in that order for precedence — see below). This is the "list of GPOs" that Event ID 1030 refers to when it fails.
5. **Filtering pass, per GPO in the enumerated list:**
   - **Security filtering** — does the computer/user object have Read + Apply Group Policy (or just Read, in which case it's listed but not applied)?
   - **WMI filtering** — does the attached WQL query evaluate true against this machine's CIM repository?
   - **Loopback processing** (computer-side setting, affects user policy application) — if enabled, either Merge (user GPOs + computer's user-targeted GPOs appended, computer wins ties) or Replace (computer's user-targeted GPO list entirely substitutes the user's own).
6. **SYSVOL retrieval.** For each GPO that survives filtering, the client reads `gpt.ini` from SYSVOL to get the authoritative version number and compares it against the cached local version. If they match and nothing else changed, most CSEs skip re-applying (this is why `gpupdate /force` exists — it bypasses the version-check optimization).
7. **Client-Side Extension (CSE) processing.** Each settings category (Registry-based/Administrative Templates, Security Settings, Group Policy Preferences, Scripts, Software Installation, Folder Redirection, etc.) is handled by its own CSE DLL, invoked in a defined order, each writing to its own local cache/state. A CSE failure is isolated to that CSE — e.g., a corrupt `Registry.pol` produces Event 1096 but doesn't necessarily block other CSEs from applying.
8. **Precedence resolution.** Final effective settings are computed as: Local GPO → Site-linked GPOs → Domain-linked GPOs → OU-linked GPOs (closest OU last, i.e., wins), with "Enforced" links overriding this order from the top down regardless of Block Inheritance at lower OUs, and Block Inheritance at an OU excluding all non-enforced GPOs from above it.

**Why "gpresult" is the right first tool**: `gpresult /h` (or `/r` for a quicker text summary) reads the *client's own record* of steps 4-8 above — which GPOs were enumerated, which were denied/filtered and why, and what the final winning value was per setting. It is the single artifact that answers "did this even reach the client" vs. "did the client discard it" vs. "did it apply but get overridden."
</details>

---
## Dependency Stack

```
Layer 5:  GPO effective settings on the client (CSE-applied state)
              ▲ depends on
Layer 4:  Client-Side Extension processing (Registry.pol, GPP, Scripts, Security, Software Install)
              ▲ depends on
Layer 3:  Filtering pipeline (Security filtering ACL, WMI filter evaluation, Loopback mode)
              ▲ depends on
Layer 2:  GPO discovery + retrieval
              — GPC enumeration via LDAP (needs AD DS replication healthy: ActiveDirectory/Troubleshooting/Replication/)
              — GPT retrieval via SYSVOL (needs DFSR replication healthy: DFS/Troubleshooting/Replication/)
              — GPC/GPT version agreement (the "two independent replication systems" seam)
              ▲ depends on
Layer 1:  Client can reach a DC at all
              — DNS SRV records resolve
              — AD Sites/Subnets routes to a correct, reachable DC
              — Kerberos auth succeeds (needs time sync: Windows/Troubleshooting/Time/)
              — SMB/445 reachable for SYSVOL share access
              ▲ depends on
Layer 0:  Network stack initialized (NLA signal) before or shortly after logon
```

A failure at any layer surfaces at Layer 5 as "the setting isn't applying" — but the fix is almost always at a lower layer. This is the single most common diagnostic mistake in this domain: engineers stare at Layer 5 symptoms and try to fix them at Layer 5 (re-editing the GPO setting) when the real fault is Layer 1 or 2.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Event 1058 "could not access gpt.ini" | SYSVOL unreachable, DFS client down, or GPT folder/file missing on the DC serving this client | `Test-Path` to the SYSVOL GPT path; `Get-Service DFS` |
| Event 1030 "could not query list of GPOs" | Usually downstream of 1058; if standalone, LDAP query to AD is failing (DC unreachable, DNS) | `nltest /dsgetdc:<domain>` |
| Event 1096 "could not apply registry-based policy" | Corrupt local `Registry.pol` cache, or malformed `.pol` on SYSVOL | Delete local cache, `gpupdate /force`; if still failing, inspect SYSVOL-side `.pol` |
| "AD / SYSVOL Version Mismatch" | DFSR replication lag between the DC that answered the LDAP query and the DC that served SYSVOL | `dfsrdiag replicationstate`; also check AD DS replication health as GPC version itself is AD-replicated |
| GPO applies on some machines in an OU, not others | Security filtering ACL scoped to a group that doesn't include the missing machines; or WMI filter excludes them (e.g., an OS-version filter after a feature update) | `Get-GPPermission -All`; evaluate the WMI filter's WQL manually with `Get-CimInstance` |
| GPO settings apply, but wrong/unexpected values win | Precedence: a closer-linked or Enforced GPO is overriding; or Block Inheritance at an intermediate OU | `gpresult /h` → "Winning GPO" per setting |
| Logons take much longer after a change | New Enforced GPO doing Folder Redirection/Software Install over slow link, or CSE processing pile-up from newly-linked GPOs at a busy OU | Check Event 8006/8007 processing duration deltas; check slow-link detection status |
| User-targeted settings behave differently depending on which computer they log into | Loopback processing configured on some computer OUs, not others (by design, or misconfigured) | `Get-GPO` loopback mode on the relevant computer OU's GPOs |
| A GPO edited an hour ago hasn't taken effect anywhere | DFSR SYSVOL replication backlog (whole domain affected, not just processing pipeline) | `dfsrdiag replicationstate`, `dfsrdiag backlog` |
| GPO works after `gpupdate /force` but not on natural background refresh | Background refresh interval (default ~90-120 min, randomized) hasn't elapsed yet, or slow-link detection is skipping the specific CSE in background mode | Check GroupPolicy Operational log for the last natural refresh attempt and its skip reason |

---
## Validation Steps

1. **Confirm the client can see and enumerate the GPO at all.**
   ```powershell
   gpresult /h "$env:TEMP\gpresult.html"; Invoke-Item "$env:TEMP\gpresult.html"
   ```
   Good: GPO appears under "Applied GPOs" for the correct target (Computer or User). Bad: appears under Denied/Filtered, or doesn't appear at all (not enumerated — check linking/scope).

2. **Confirm AD-side GPC version.**
   ```powershell
   Get-GPO -Name "<GPO-Display-Name>" | Select DisplayName, Id, User, Computer
   ```
   Good: version numbers increment as expected after edits. Bad: version frozen despite edits saved in GPMC (points to an AD DS replication problem on the DC you edited against, or you edited against a DC that itself isn't replicating out).

3. **Confirm SYSVOL-side GPT version.**
   ```powershell
   Get-Content "\\<domain>\SysVol\<domain>\Policies\{<GUID>}\gpt.ini"
   ```
   Good: `Version=` matches (or is very close to, if just edited) the GPC version above. Bad: static/stale version — DFSR isn't propagating this GPO's folder to this DC or this client's serving DC.

4. **Confirm DFSR replication health for SYSVOL specifically.**
   ```powershell
   dfsrdiag replicationstate
   dfsrdiag backlog /rgname:"Domain System Volume" /rfname:"SYSVOL Share" /sendingmember:<DC1> /receivingmember:<DC2>
   ```
   Good: zero backlog, no errors. Bad: growing backlog count — treat as a `DFS/Troubleshooting/Replication/` incident, not a Group Policy one.

5. **Confirm security filtering and WMI filter evaluate as intended.**
   ```powershell
   Get-GPPermission -Name "<GPO-Display-Name>" -All
   Get-CimInstance -Query "<WQL-from-filter>"  # run ON the target machine
   ```
   Good: target principal has GpoApply; WQL returns a result set (non-empty/true). Bad: principal missing from ACL, or WQL returns empty/errors (often after an OS feature update changes `Version` strings the filter was written against).

6. **Confirm precedence/winner is what's expected.**
   ```powershell
   gpresult /h "$env:TEMP\gpresult.html"  # look at "Winning GPO" column per setting in the HTML report
   ```
   Good: expected GPO wins for the setting in question. Bad: an unexpected Enforced GPO from a higher scope, or Block Inheritance excluded the intended GPO.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Reachability.** Confirm DNS SRV resolution, correct AD Site assignment, DC reachability on 445/389/88, and Kerberos time sync. If any of these fail, nothing downstream matters — fix here first.

**Phase 2 — Enumeration & version agreement.** Confirm the client's LDAP query against AD returns the expected GPO list, and that GPC/GPT versions agree. If they disagree, treat it as a replication problem (AD DS or DFSR) before touching anything Group-Policy-specific.

**Phase 3 — Filtering.** Walk security filtering, then WMI filtering, then loopback mode, in that order — each is a hard gate and the first one that excludes the object ends the inquiry for that GPO.

**Phase 4 — CSE processing.** If the GPO is enumerated, version-current, and passes filtering, but the *setting* still isn't taking effect, the fault is in CSE-specific processing — check the specific CSE's own event source (e.g., Group Policy Preferences logs separately from Administrative Templates) and its local cache state.

**Phase 5 — Precedence.** If multiple GPOs configure the same setting and the wrong one wins, this is a design/linking issue, not a fault — resolve via GPMC (link order, Enforced, Block Inheritance), not via client-side troubleshooting.

---
## Remediation Playbooks

<details><summary>Playbook 1 — DFSR-driven SYSVOL replication backlog blocking GPO rollout domain-wide</summary>

**When to use:** `dfsrdiag backlog` shows a growing count on the SYSVOL replication group, and *multiple, unrelated* GPOs all show stale GPT versions on the same DC(s).

1. Identify the receiving member(s) with backlog: `dfsrdiag backlog /rgname:"Domain System Volume" /rfname:"SYSVOL Share" /sendingmember:<hub-DC> /receivingmember:<lagging-DC>`
2. Check DFSR service health on the lagging DC: `Get-Service DFSR -ComputerName <lagging-DC>`; check the DFS Replication event log there for staging quota exhaustion (Event 4202/4204) or database issues.
3. If staging quota is the cause, increase it temporarily: `Set-DfsrMember -GroupName "Domain System Volume" -ComputerName <lagging-DC> -Confirm:$false` combined with `Set-DfsReplicatedFolder`/staging path adjustments per current replicated-folder config — validate current values before changing (see `DFS/Troubleshooting/Replication/` for the general DFSR remediation playbook, which this defers to).
4. Force a poll/resync: `dfsrdiag PollAD /Member:<lagging-DC>`
5. Re-validate: `dfsrdiag backlog ...` returns to zero within a normal replication interval.

**Rollback:** if staging quota was raised, consider reverting to prior value once backlog clears, to avoid uncontrolled disk usage. No GPO-specific rollback is needed — this playbook only touches DFSR configuration.
</details>

<details><summary>Playbook 2 — Corrupt GPO (bad Registry.pol or malformed GPT) requires rebuild</summary>

**When to use:** Event 1096 or CSE-specific errors persist for one specific GPO across multiple, otherwise-healthy clients, and the SYSVOL-side files for that GPO look suspect (0-byte, malformed XML/pol, or `gpt.ini` missing the `Version=` line).

1. Back up the GPO first: `Backup-GPO -Name "<GPO-Display-Name>" -Path <backup-folder>`
2. Inspect the SYSVOL folder contents directly for the GUID in question: `Get-ChildItem "\\<domain>\SysVol\<domain>\Policies\{<GUID>}" -Recurse`
3. If `gpt.ini` is missing the `Version=` line or is corrupt, the safest fix is a no-op edit in GPMC (open the GPO, make and immediately revert a trivial change, save) — this forces Windows to regenerate `gpt.ini` correctly and bump the GPC version to force replication.
4. If the corruption is deeper (malformed Registry.pol, missing ADM template files), restore from the backup taken in step 1, or from a known-good GPO backup if this is the first time you're touching it: `Restore-GPO -Name "<GPO-Display-Name>" -Path <backup-folder>`
5. Force SYSVOL replication out and validate on 2-3 affected clients with `gpupdate /force` + `gpresult /h`.

**Rollback:** the backup taken in step 1 is the rollback point — `Restore-GPO` from it undoes any changes made during remediation.
</details>

<details><summary>Playbook 3 — Loopback processing misconfigured causing inconsistent user experience across shared/kiosk machines</summary>

**When to use:** Users report different Start menu/desktop/mapped-drive experiences depending on which physical machine (e.g., a shared workstation pool) they log into, and loopback processing is intentionally configured on some computer OUs.

1. Confirm which computer OU(s) have loopback configured and in what mode: `Get-GPO` + GPMC review of Computer Configuration > Policies > Administrative Templates > System > Group Policy > "Configure user Group Policy loopback processing mode."
2. Confirm the computer object (not just the user) has Read + Apply Group Policy on every GPO it's expected to merge/replace — this is the #1 real cause of "loopback isn't working," not the loopback mechanism itself.
3. Decide Merge vs Replace deliberately: Merge is safer for shared machines that still need some baseline user policy; Replace is appropriate for locked-down kiosks where you want zero carry-over from the user's normal profile.
4. Test on one machine in the affected OU with a test user account before wider rollout: `gpresult /h` post-logon should show the expected merged/replaced GPO list under the User section.

**Rollback:** set loopback mode back to "Not Configured" on the computer OU's GPO; this is a single setting change with no cascading side effects beyond reverting to normal per-user processing on next logon/refresh.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects a full Group Policy diagnostic evidence pack for escalation.
#>
$out = "$env:TEMP\GPO-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -Path $out -ItemType Directory -Force | Out-Null

gpresult /h "$out\gpresult.html"
gpresult /r  *> "$out\gpresult-summary.txt"
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 500 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$out\gpo-operational-log.csv" -NoTypeInformation

Get-Service DFS, DFSR -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType |
    Export-Csv "$out\dfs-services.csv" -NoTypeInformation

nltest /dsgetdc:$env:USERDNSDOMAIN *> "$out\dc-locator.txt"
w32tm /stripchart /computer:$env:LOGONSERVER.Trim('\') /samples:3 /dataonly *> "$out\time-sync.txt" 2>$null

dfsrdiag replicationstate *> "$out\dfsr-replicationstate.txt" 2>$null

Compress-Archive -Path $out -DestinationPath "$out.zip" -Force
Write-Host "Evidence pack: $out.zip"
```
</details>

Attach the resulting zip plus: the exact GPO name/GUID, affected OU(s), and whether the issue is new (post-change) or longstanding.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `gpresult /h report.html` | Full HTML report: applied/denied/filtered GPOs, winning settings, version mismatch flags |
| `gpresult /r` | Quick text summary of applied GPOs |
| `gpupdate /force` | Force full re-application, bypassing version-check optimization |
| `gpupdate /force /wait:120` | Same, with a bounded wait for completion (useful in scripted checks) |
| `Get-GPO -Name "<name>"` | AD-side GPO object: GUID, version, status |
| `Get-GPOReport -Name "<name>" -ReportType Html` | Full settings report for a specific GPO |
| `Get-GPPermission -Name "<name>" -All` | Security filtering ACL |
| `Get-GPInheritance -Target "<OU-DN>"` | Inheritance/blocking state for an OU |
| `Set-GPPermission` | Grant/modify GpoApply rights |
| `Backup-GPO` / `Restore-GPO` | GPO-level backup/restore |
| `dfsrdiag replicationstate` | SYSVOL DFSR replication health snapshot |
| `dfsrdiag backlog` | Specific backlog count between two DCs for a replicated folder |
| `dfsrdiag PollAD /Member:<DC>` | Force a DC to re-poll AD for DFSR config/topology changes |
| `nltest /dsgetdc:<domain>` | Which DC is this client using, and is it reachable |
| `w32tm /stripchart /computer:<DC>` | Kerberos-relevant time offset check |
| `Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational"` | The single most useful log source for this domain |

---
## 🎓 Learning Pointers
- Internalize the two-replication-system model: GPC (AD DS) and GPT (DFSR/SYSVOL) are independent systems with independent failure modes. "Version mismatch" is the client telling you these two systems disagree — the fix is always in one of the two replication layers, never in the Group Policy Client itself. See [DFSR SYSVOL fails to migrate or replicate](https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/dfsr-sysvol-fails-migrate-replicate).
- Build the habit of reading `gpresult /h` top-to-bottom before touching anything — it encodes the exact filtering pipeline (enumerated → security-filtered → WMI-filtered → applied) and tells you which layer to investigate without guessing.
- Fast Boot/Fast Logon means "background" policy processing is now the common case, not the exception, on modern Windows — several CSEs (Software Installation, Folder Redirection) deliberately skip background passes. A setting that "only applies after two reboots" is often working exactly as designed, not broken.
- Slow-link detection thresholds were originally tuned for dial-up-era bandwidth assumptions; on modern high-latency-but-high-bandwidth VPNs (satellite, some SD-WAN configs) the default measurement can misfire. Don't disable it reflexively — understand what it measured first. See [Group Policy Slow Link Detection](https://www.rebeladmin.com/group-policy-slow-link-detection/).
- Read [Back to the Loopback: Troubleshooting Group Policy loopback processing](https://techcommunity.microsoft.com/blog/askds/back-to-the-loopback-troubleshooting-group-policy-loopback-processing-part-2/400218) — an old but still-accurate AskDS deep dive on the #1 misdiagnosed loopback failure mode (security filtering, not loopback mechanics).
- Cross-reference `ActiveDirectory/Troubleshooting/Replication/AD-Replication-A.md` whenever GPC version numbers appear frozen across all DCs, not just one — that's an AD DS replication problem wearing a Group Policy costume, same pattern as the SYSVOL/DFSR case but one layer down.
