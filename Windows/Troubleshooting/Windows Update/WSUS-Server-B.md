# WSUS Server Health — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage

**This runbook covers the WSUS server role itself** — SUSDB health, the WsusPool IIS application pool, and content store integrity. It does not cover the client-side "which update source is a device actually scanning against" question — see `WSUS to WfUB B.md` for dual-scan/WUfB-migration client behavior. It also does not cover ConfigMgr's own Software Update Point (SUP) sync logic beyond noting where ConfigMgr changes standalone-WSUS maintenance steps.

```powershell
# 1. Core service state — the fastest single "is WSUS up" check
Get-Service WsusService, W3SVC | Select-Object Name, Status, StartType

# 2. IIS WsusPool health (the #1 cause of "console won't open"/timeouts)
Import-Module WebAdministration
Get-WebAppPoolState -Name WsusPool

# 3. Content store vs. database consistency (self-check, may take a while)
& "$env:ProgramFiles\Update Services\Tools\wsusutil.exe" checkhealth

# 4. Disk space on the content directory volume — silent-fail cause
Get-PSDrive -Name (Split-Path (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup").ContentDir -Qualifier).TrimEnd(':') |
  Select-Object Used, Free

# 5. Recent WSUS-specific errors
Get-WinEvent -LogName Application -MaxEvents 100 |
  Where-Object { $_.ProviderName -eq "Windows Server Update Services" -and $_.LevelDisplayName -eq "Error" }
```

| Finding | Interpretation | Do this |
|---|---|---|
| WSUS console shows "unexpected error", hangs, or won't open | WsusPool crashed/recycling, or MMC cache corrupted | **Fix 1** |
| Clients stuck at 0% scan progress or timing out | WsusPool exhausted (memory limit hit) or IIS not responding | **Fix 1** |
| Cleanup Wizard times out repeatedly / has never completed | SUSDB never maintained — index/obsolete-update backlog | **Fix 2** |
| `wsusutil checkhealth` reports content/metadata mismatches | Content files missing/corrupted relative to SUSDB records | **Fix 3** |
| Content directory volume shows very low free space | Content store growth outpaced disk, or cleanup never run | **Fix 4** |
| Clients report `0x8024401C`/`0x80244010`/similar SoapException | WSUS server not responding to client SOAP calls — usually WsusPool | **Fix 1**, then **Fix 5** |
| Downstream/replica servers not receiving updates from upstream | Sync failing at the upstream tier — check upstream first, then replicas | **Fix 5** |
| SUSDB itself won't mount / WID corruption suspected | Database-level corruption, not just content — highest-severity path | **Fix 6** |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
WsusService (Windows Server Update Services service) — running
    │
IIS (World Wide Web Publishing Service, W3SVC) running
    │
WsusPool application pool — Started, not recycling/crashing
  (memory pressure on large installs is the #1 real-world cause of
  crashes — default Private Memory Limit can be too low)
    │
SUSDB database — either Windows Internal Database (WID, the default
  for standalone WSUS) or a full SQL Server instance
    │
Content directory (WSUSContent, typically on a separate large volume)
  — every update record in SUSDB must correspond to an actual file
  here, or clients fail to download approved updates
    │
Clients reach the WSUS server over the configured port (8530/8531 by
  default, or 80/443 on older configurations) and complete a SOAP-based
  scan/download cycle
    │
Hierarchy (if used): downstream/replica WSUS servers sync from an
  upstream server — cleanup and decline-superseded steps must run
  BOTTOM-UP, sync/replication flows TOP-DOWN
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm core services**
```powershell
Get-Service WsusService, W3SVC | Select-Object Name, Status, StartType
```
Expected: both `Running`. `WsusService` stopped is a hard outage; `W3SVC` stopped takes the console and client scanning down together.

**2. Confirm the IIS application pool specifically**
```powershell
Import-Module WebAdministration
Get-WebAppPoolState -Name WsusPool
Get-Item "IIS:\AppPools\WsusPool" | Select-Object -ExpandProperty recycling
```
Expected: `Started`. A pool that shows `Stopped` or that recycles far more often than its configured schedule points at a crash, most commonly memory exhaustion on larger WSUS installs.

**3. Confirm the WSUS self-health check**
```powershell
& "$env:ProgramFiles\Update Services\Tools\wsusutil.exe" checkhealth
Get-WinEvent -LogName Application -MaxEvents 20 |
  Where-Object { $_.ProviderName -eq "Windows Server Update Services" -and $_.Id -eq 12052 }
```
Expected: the resulting Event ID 12052 entry reports no content/metadata mismatches. This can take a long time on a large content store — run it during a maintenance window, not as a first-response check under active incident pressure.

**4. Confirm disk space on the content volume**
```powershell
$contentDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup").ContentDir
Get-PSDrive -Name (Split-Path $contentDir -Qualifier).TrimEnd(':') | Select-Object Used, Free
```
Expected: comfortable free space margin. WSUS does not fail loudly when the content volume fills — new content simply fails to download, and clients report generic download errors.

**5. Confirm which database engine SUSDB runs on, before any database-level troubleshooting**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name SqlServerName
```
Expected: a value containing `##SSEE` or `##WID` means Windows Internal Database (requires SQL Server Management Studio to connect via a named pipe); a plain server\instance name means a full SQL Server instance (standard SSMS connection). The reindex/maintenance procedure differs by which of these is in play — confirm before following generic "connect to SUSDB" instructions.

---
## Common Fix Paths

<details><summary>Fix 1 — Console hangs / WsusPool crashing or exhausting memory</summary>

```powershell
# Confirm the pool is actually the problem
Get-WebAppPoolState -Name WsusPool
Get-WinEvent -LogName System -MaxEvents 50 |
  Where-Object { $_.ProviderName -eq "WAS" -and $_.Message -match "WsusPool" }

# Raise the private memory limit (0 = unlimited) and relax rapid-fail
# protection, which otherwise stops the pool after repeated crashes
# instead of letting it recover
Import-Module WebAdministration
Set-ItemProperty "IIS:\AppPools\WsusPool" -Name recycling.periodicRestart.privateMemory -Value 0
Set-ItemProperty "IIS:\AppPools\WsusPool" -Name failure.rapidFailProtection -Value $false
Set-ItemProperty "IIS:\AppPools\WsusPool" -Name queueLength -Value 25000

# Clear the local MMC console cache (a stale cache is a separate, common
# cause of "unexpected error" that looks identical to a pool crash)
Remove-Item "$env:APPDATA\Microsoft\MMC\WSUS" -Force -ErrorAction SilentlyContinue

# Restart IIS and re-test the console
iisreset
```
**Rollback:** re-enabling rapid-fail protection and restoring a private memory limit is possible by reversing the same `Set-ItemProperty` commands with the prior values if a subsequent investigation shows the unbounded pool is masking a genuine memory leak rather than fixing under-provisioning.
</details>

<details><summary>Fix 2 — Cleanup Wizard times out / has never completed</summary>

```powershell
# Confirm the scale of the backlog before attempting cleanup
# (run against SUSDB — see WSUS-Server-A.md for connection details by
# database engine type)
# SELECT COUNT(UpdateID) FROM vwMinimalUpdate WHERE IsSuperseded=1 AND Declined=0

# If the Cleanup Wizard has genuinely never completed on this server,
# reindex FIRST — cleanup on an unindexed multi-year SUSDB is what times out
& "$env:ProgramFiles\Update Services\Tools\wsusutil.exe" checkhealth

# Then run the Cleanup Wizard with ONLY "Unused updates and update
# revisions" checked for the first pass — the heaviest single option
# Options > Server Cleanup Wizard, in the WSUS console

# Once the first pass completes, run a full pass with all options checked
```
**Rollback:** N/A — cleanup only removes update metadata/files already superseded, expired, or declined. Back up SUSDB before a first-ever cleanup on a long-neglected server regardless, since first-run cleanups touch the largest volume of data.
</details>

<details><summary>Fix 3 — Content/metadata mismatch (checkhealth reports missing files)</summary>

```powershell
# wsusutil reset re-downloads any update file that SUSDB references but
# that is missing or corrupted on disk — safe, but can trigger a large
# re-download depending on how much content is actually missing
& "$env:ProgramFiles\Update Services\Tools\wsusutil.exe" reset

# Monitor progress via the WSUS event log — this can take hours on a
# large content store and will re-saturate the sync schedule; run in a
# maintenance window
Get-WinEvent -LogName Application -MaxEvents 20 |
  Where-Object { $_.ProviderName -eq "Windows Server Update Services" }
```
**Rollback:** N/A — `wsusutil reset` only re-validates and re-downloads content; it does not alter approvals, groups, or computer records. Ensure sufficient free disk space and bandwidth before running, since it can generate a large synchronous download burst.
</details>

<details><summary>Fix 4 — Content volume low on disk space</summary>

```powershell
# Confirm current usage
$contentDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup").ContentDir
Get-ChildItem $contentDir -Recurse -ErrorAction SilentlyContinue |
  Measure-Object -Property Length -Sum | Select-Object @{N='SizeGB';E={[math]::Round($_.Sum/1GB,1)}}

# Run cleanup to reclaim space from superseded/expired/declined updates
# (see Fix 2) BEFORE resorting to volume expansion

# If genuinely undersized for the product/classification scope selected,
# either expand the volume or narrow WSUS's product/classification/
# language scope in Options > Products and Classifications
```
**Rollback:** N/A — cleanup is non-destructive to still-needed content; narrowing product/classification scope going forward does not remove already-downloaded content until the next cleanup pass declines it.
</details>

<details><summary>Fix 5 — Clients get SOAP/timeout errors (0x8024401C, 0x80244010, etc.)</summary>

```powershell
# Confirm the server side is actually responding on the client scan port
Test-NetConnection -ComputerName localhost -Port 8530

# Cross-check IIS/WsusPool health first — this class of client error is
# very frequently a server-side symptom (Fix 1), not a client fault
Get-WebAppPoolState -Name WsusPool

# If server-side checks are clean, confirm from an affected client that
# it is reaching the correct, currently-configured WSUS URL
(Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue).WUServer
```
**Rollback:** N/A — diagnostic. If the root cause is confirmed server-side, apply Fix 1; if genuinely client-side, see `WSUS to WfUB B.md`.
</details>

<details><summary>Fix 6 — SUSDB corruption suspected (last resort)</summary>

```powershell
# Confirm which engine SUSDB runs on first (see Diagnosis step 5) — the
# recovery path differs for WID vs. full SQL Server

# Back up SUSDB before any destructive step, by whichever method matches
# the engine in use (see WSUS-Server-A.md for engine-specific detail)

# If reindexing and wsusutil reset (Fixes above) do not resolve it, and a
# recent clean backup does not exist, a full reinstall reattached to the
# existing content directory is the documented recovery path — this is a
# significant action requiring a maintenance window and stakeholder
# awareness of the initial-sync/full-client-scan impact that follows
```
**Rollback:** N/A at this severity — this IS the recovery path. Escalate with the full Escalation Evidence pack before proceeding if any doubt exists about which engine SUSDB uses or whether a usable backup exists.
</details>

---
## Escalation Evidence

```
WSUS Server Escalation
------------------------
Date/Time issue started:
WSUS server name, port (8530/8531 or 80/443), standalone or ConfigMgr SUP:
Get-Service WsusService, W3SVC output:
Get-WebAppPoolState -Name WsusPool output, and recent WAS/W3SVC crash events:
wsusutil checkhealth result (Event ID 12052 detail):
Content directory free space:
SUSDB engine (WID or SQL Server — from SqlServerName registry value):
Last successful cleanup wizard run / last known maintenance date:
Client-side error codes observed, and how many clients affected:
Recent changes (Windows Update, WSUS role update, storage change, ConfigMgr SUP config change):
Attempted fixes and results:
```

---
## 🎓 Learning Pointers

- **"I set up WSUS and never touched it again" is the single most common root cause of every symptom in this file** — WSUS explicitly requires monthly maintenance (reindex, decline superseded updates, cleanup wizard); skipping it for years is what turns a five-minute cleanup into a multi-hour, timeout-prone recovery. See [The complete guide to WSUS and Configuration Manager SUP maintenance](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/wsus-maintenance-guide).
- **A crashing WsusPool masquerades as a database problem** — "console won't open," "clients time out," and some SOAP error codes all commonly trace back to IIS application pool memory exhaustion, not SUSDB corruption. Check `Get-WebAppPoolState` before reaching for database-level tools.
- **`wsusutil reset` fixes content/metadata mismatches, not database corruption** — know which failure mode you're actually looking at (`checkhealth` output) before picking a repair tool; the two require different fixes.
- **If ConfigMgr manages this WSUS server as a Software Update Point, most of this maintenance is automatable** — the WSUS Maintenance options in SUP Component Properties (version 1906+) handle decline/cleanup automatically; only backup and reindexing still need to be scheduled separately.
- **In a multi-tier hierarchy, cleanup runs bottom-up and sync runs top-down** — running maintenance out of this order risks re-syncing content you just cleaned out of a downstream server from its still-uncleaned upstream.
- **For SUSDB-engine-specific reindex/backup procedures and the full maintenance cadence, see `WSUS-Server-A.md`.**
