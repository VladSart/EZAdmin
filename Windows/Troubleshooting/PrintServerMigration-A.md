# Print Server Migration — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Migrating shared print queues, drivers, ports, forms, and per-queue security from one Windows print server to another (same or newer OS, physical or virtual/Azure VM), using the Print Management "Migrate Printers" wizard and/or the underlying `Printbrm.exe` command-line tool
- The zero-client-reconfiguration cutover pattern (rename-based identity swap)
- Cross-architecture (x86 ↔ x64) and cross-OS-generation migrations, including the January 2026 legacy (V3/V4) printer driver publishing change and its effect on migrations landing on Windows Server 2025+/Windows 11 24H2+ destinations
- Rollback and decommission planning for the source server

**Does not cover:**
- File-server data migration — that's `StorageMigrationService-A.md`; SMS does not migrate print queues at all, it's a separate tool for a separate role
- Migrating TO cloud-based Universal Print (eliminating the print server rather than moving it) — see `M365/UniversalPrint/Universal-Print-A.md`
- General Print Spooler crash/queue troubleshooting on a server that isn't being migrated — see `PrintSpooler-A.md`/`PrintSpooler-B.md`
- Printer driver security hardening (Point and Print restrictions, PrintNightmare mitigations) as an ongoing posture — covered in `PrintSpooler-A.md`; only the migration-specific interaction (Fix 2 in the hotfix runbook) is addressed here
- macOS/Linux print server migration (CUPS) — see `macOS/` folder

**Assumptions:**
- Both source and destination are running a supported Windows Server version with the Print and Document Services role available
- Engineer has local admin (or domain admin, for an AD DS-integrated environment) on both source and destination
- A maintenance window exists for the cutover phase, even though the migration/backup/restore phases themselves can happen with the source fully in production

---

## How It Works

<details><summary>Full architecture</summary>

**The tool, not just the wizard.** The Print Management console's "Migrate Printers" wizard (Action → Migrate Printers, on a Print Servers node) is a GUI front end over the same backup/restore/migration (BRM) engine as the command-line tool, `Printbrm.exe` (`%SystemRoot%\System32\spool\tools\Printbrm.exe`). Anything the wizard can do, PrintBRM can do scripted and unattended — the wizard is a convenience layer, not a functionally different migration path.

**Backup produces a single portable archive.** Running a backup (`-b`) against a source server produces one compressed `.printerExport` file (a CAB-based container) holding several internal XML manifests plus binary driver files:
- `BrmPrinters` — every installed printer queue and its configuration
- `BrmDrivers` — the full list of installed drivers, plus the driver binaries themselves
- `BrmPorts` — every installed printer port
- `BrmForms` — installed paper forms
- `BrmLMons` — language monitors and their architecture (x86/x64) and port-monitor files
- `BrmSpoolerAttrib` — spooler directory path, and whether the source was a cluster server

**Restore is additive to the destination, not destructive to the source.** `-r` unpacks and applies the archive to a target server. Nothing on the source is ever touched by a backup or restore operation — the source remains fully in production throughout, which is why the actual client-facing outage window can be compressed down to just the cutover rename step, not the whole migration project.

**The `-nobin` + `DriverMap` pattern is the modernization lever.** A backup taken with `-nobin` omits driver binaries entirely, producing a smaller archive that references drivers by name only. Combined with a `BrmConfig.xml` configuration file's `<DriverMap>` section (mapping an old driver name to a new one already installed on the destination), this is the supported way to land old print queues onto current, signed, IPP-Class-Driver-era drivers during the SAME restore operation — rather than migrating the old driver as-is and hoping it still installs.

**Local bus and plug-and-play printers are a hard, permanent exclusion.** USB, LPT, and COM-attached printers, and any true plug-and-play printer, are visible in a PrintBRM backup manifest (the tool inventories them) but categorically cannot be restored to a different physical machine — there is no virtual USB/LPT bus to reattach them to on the destination. This is not a bug or a missing feature; it's a structural limitation of what "migrating a printer" can mean for hardware that's directly wired into one specific box.

**Cross-architecture restores fail on language monitors specifically.** A language monitor (the component that talks to certain port types/protocols on behalf of a driver) is compiled for one CPU architecture. Restoring an export from an x86 source onto an x64 destination — or the reverse — succeeds for the printer queue itself but throws an explicit error for any printer whose driver depends on a language monitor, because the x86 language monitor binary simply cannot load on x64 (or vice versa). The documented recovery is to manually install the standard driver for the destination's own architecture after the restore completes.

**The cutover is a rename, not a DNS trick or a load balancer.** Client machines hold a literal UNC path (`\\servername\printername`) in their print queue configuration — there is no abstraction layer between "the server the client thinks it's talking to" and "the server's actual NetBIOS/DNS name." The only way to move printing to new hardware WITHOUT touching every client machine is for the new hardware to end up carrying the exact same name the old hardware had. This is why the documented migration procedure ends in a two-phase rename (destination → temporary name, source → retired name, destination → original source name) rather than any kind of redirect.

**Rollback has a hard cutoff, not a time limit.** Rollback (renaming both servers back to their pre-migration identities) works at any point — UNTIL source retirement begins. "Retirement" specifically means deleting print queues, closing print connections, reformatting drivers, or removing hardware from the source. Before that point, rollback is a five-minute rename operation. After it, the only path forward is restarting the entire migration from a fresh backup — there's no partial-undo.

</details>

---

## Dependency Stack

```
Print and Document Services role  (installed on BOTH source and destination)
   └── PrintBRM.exe   (%SystemRoot%\System32\spool\tools\ — CLI engine)
   └── Print Management console  (GUI wrapper — Migrate Printers wizard)
        │
Print$ SMB share  (auto-created by the role — driver-store share PrintBRM
                    reads/writes through for REMOTE backup/restore operations)
Remote Registry service  (must be RUNNING on both ends for remote operations —
                           not required for a local-export-then-copy workflow)
        │
BACKUP (-b) — produces one .printerExport archive:
   BrmPrinters · BrmDrivers (+ binaries unless -nobin) · BrmPorts
   BrmForms · BrmLMons (architecture-bound) · BrmSpoolerAttrib
        │
   [OPTIONAL] BrmConfig.xml  →  <DriverMap> old→new driver substitution
   [OPTIONAL] -D <folder>    →  unpack for manual XML editing, then repack
        │
RESTORE (-r) — applies the archive to the destination:
   ✗ Local bus (USB/LPT/COM) printers — inventoried, never restorable
   ✗ True plug-and-play printers — inventoried, never restorable
   ✗ Language monitors on a cross-architecture restore — errors, printer
     queue itself still restores, driver needs manual reinstall
   ✗ LPR printers — requires LPR Port Monitor feature pre-installed on
     destination, or -lpr2tcp to convert the port type during restore
   ✗ System/custom local permissions — ONLY printer-queue-level ACLs migrate
        │
Destination printer queues online + driver-verified
        │
[OPTIONAL] CUTOVER — two-phase rename identity swap:
   1. Unpublish source from AD DS (if published)
   2. Rename destination → temporary name
   3. Rename source → retired name (begin decommission per policy)
   4. Rename destination → source's ORIGINAL name
   5. Publish destination to AD DS (if desired), only after step 4
        │
   Client UNC paths (\\originalname\printer) now resolve to the new
   hardware with ZERO client-side reconfiguration
        │
Rollback window CLOSES the moment source retirement (step 3's queue
deletion / driver removal / hardware pull) begins
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Backup/restore over the network fails with an access or connectivity error | `Print$` share missing or Remote Registry not running on the target | `Get-SmbShare -Name Print$`, `Get-Service RemoteRegistry` on both ends |
| Restore succeeds but destination shows a driver error on WS2025+/Win11 24H2+ | Legacy V3/V4 driver no longer auto-fetchable from Windows Update since Jan 15, 2026 | `Get-Printer -ComputerName <dest>` driver name/status; check vendor's current driver package |
| Restore errors specifically on a language monitor | Cross-architecture (x86↔x64) migration — language monitors are architecture-bound | Compare `[Environment]::Is64BitOperatingSystem` on source vs. destination |
| A local-bus (USB/LPT/COM) printer is "missing" post-migration | Never migratable by design — inventoried, not restorable | `Get-Printer \| Where PortName -match "USB\|LPT\|COM"` on the source, pre-migration |
| A plug-and-play printer is "missing" post-migration | Same structural exclusion as local bus | Confirm port type/connection method pre-migration |
| LPR printer restore fails outright | LPR Port Monitor feature not present on destination | `Get-WindowsFeature Print-LPD-Print-Server-Fixed-Port` |
| Same printer appears twice in AD DS after cutover | Source published to AD DS at the same time as (or before) destination's rename completed | `Get-Printer \| Select Name, Published` on both source and destination |
| Client print jobs fail after a "successful" migration | Two-phase rename sequence incomplete, out of order, or the printer/share name itself changed | Compare `$env:COMPUTERNAME` pre/post on both boxes against the client's existing connection string |
| `spoolsv.exe` crashes or hangs mid-restore | A specific legacy/buggy driver is crashing the spooler process during import | Enable print driver isolation GPO, retry; isolate the offending printer if it recurs |
| Restore reports success but only some printers/queues actually landed | A selective restore (`-d` workflow) was used and the manually-edited manifest omitted entries, or an individual queue failed silently and only logged to the migration event channel | `Printbrm.exe -Q -F <file>` to re-list contents; check PrintBRM event log for per-queue failures |
| Downloading a large migration log/report times out | Not applicable to PrintBRM directly — this is a Storage Migration Service (WAC) symptom, not print (see `StorageMigrationService-B.md` Fix 9) | Confirm which tool is actually in use before troubleshooting the wrong one |
| Migration "succeeded" but queue-level permissions differ from source | Only printer-QUEUE ACLs migrate — system permissions and custom local permissions are explicitly NOT part of the migration | Manually compare queue security tabs; re-apply any custom local permissions by hand |

---

## Validation Steps

**1. Confirm the backup archive is structurally valid before trusting it for a restore:**
```powershell
& "$env:SystemRoot\System32\spool\tools\PrintBRM.exe" -Q -F C:\Temp\printers.printerExport
```
Expected: a clean listing of printers, drivers, and ports with no error. If this fails, the export itself is bad — don't proceed to troubleshooting the restore.

**2. Confirm the Print and Document Services role and its prerequisites on BOTH ends:**
```powershell
Get-WindowsFeature -Name Print-Server | Select-Object Name, Installed
Get-SmbShare -Name "Print$"
Get-Service -Name RemoteRegistry | Select-Object Status
```
Expected: `Installed = True`, `Print$` present, `RemoteRegistry` = `Running` (the last one only matters for a cross-machine operation).

**3. Confirm printer queue state and driver identity on the destination post-restore:**
```powershell
Get-Printer -ComputerName <destination> | Select-Object Name, DriverName, PrinterStatus, Shared
```
Expected: `PrinterStatus = Normal` and `Shared = True` for every migrated queue. A driver name that doesn't match what you expect is very often the Jan 2026 legacy-driver change on a modern destination, not a corrupted restore.

**4. Confirm which printers were structurally excluded and manually complete them:**
```powershell
Get-Printer -ComputerName <source> | Where-Object { $_.PortName -match "^(USB|LPT|COM)" }
```
Cross-check this list against the destination — every entry here needs manual physical reconnection and re-sharing, not a re-run of the restore.

**5. Confirm queue-level security migrated (and flag anything beyond it for manual review):**
```powershell
Get-Printer -ComputerName <destination> -Name "<QueueName>" | Get-PrinterProperty
```
Migration preserves printer-queue permissions only — document any system-level or custom local permissions on the source separately, since those never travel with the migration by design.

**6. Confirm the correct event log for the destination's current install state:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-PrintService/Admin" -MaxEvents 20 -ErrorAction SilentlyContinue
Get-WinEvent -LogName "Microsoft-Windows-PrintBRM/Admin" -MaxEvents 20 -ErrorAction SilentlyContinue
```
Which channel is populated depends on whether Print and Document Services was already installed on the destination when the restore ran — check both rather than assuming.

**7. Post-cutover only: print a real test job from a client's EXISTING connection:**
```powershell
Get-Printer | Where-Object { $_.ComputerName -eq "<original server name>" } | Out-Printer
```
This is the only validation that actually exercises the client's pre-existing UNC path — a fresh connection from a client would succeed even if the rename sequence was botched.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Pre-Migration Assessment**
- Inventory every printer on the source: `Get-Printer`, flagging local-bus/USB/LPT ports, LPR ports, and any driver whose vendor package predates ~2020 (a rough proxy for "likely still on a V3/V4 legacy model")
- Confirm source and destination CPU architecture match, or plan the language-monitor manual-reinstall step if they don't
- Confirm the destination's target OS (especially WS2025+/Windows 11 24H2+) and cross-check driver availability against the vendor's CURRENT package, not what Windows Update auto-installed historically
- Confirm the Print and Document Services role, `Print$` share, and Remote Registry service are ready on both ends

**Phase 2 — Backup/Export Validation**
- Run the backup (`-b`), consider `-nobin` if drivers will be substituted on restore rather than carried as-is
- Immediately query the resulting file (`-Q`) before doing anything else with it
- For a cross-domain migration, note that `-noacl` will be needed at restore time (queue ACLs from a different domain are meaningless on the destination anyway)

**Phase 3 — Restore/Import Diagnosis**
- Run the restore (`-r`), with `-o force` if re-running against a partially-populated destination
- If a `BrmConfig.xml` DriverMap is in use, confirm the NEW driver is already installed on the destination before the restore runs — PrintBRM substitutes by name, it does not install drivers for you
- Watch for language-monitor errors (cross-architecture) and LPR errors (missing port monitor feature) as expected, recoverable failure modes rather than migration-blocking bugs
- Check both possible event log channels (Phase-dependent — see Validation Step 6)

**Phase 4 — Cutover & Rename Sequence**
- Confirm every migrated queue is verified (Phase 3 output, Validation Steps 3–5) BEFORE starting any rename — this phase is the actual client-facing outage window, keep it short
- Unpublish source from AD DS first, always, regardless of rename order
- Execute the two-phase rename in the documented order; do not skip the temporary-name step, as renaming the destination directly to the source's name while the source still holds that name will fail or create a naming conflict
- Publish the destination to AD DS only after its final rename completes

**Phase 5 — Post-Migration Verification & Decommission**
- Print real test jobs from EXISTING client connections, not fresh ones (Validation Step 7)
- Confirm no duplicate AD DS printer objects remain
- Only after full validation, begin source retirement per organizational decommission policy — remember this is the point of no return for rollback
- Archive the `.printerExport` backup file itself as part of the change record; it's a complete, restorable snapshot of the pre-migration state

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full scripted migration, single command pair, same architecture</summary>

The straightforward case: same CPU architecture, no driver substitution needed, no LPR printers, willing to accept `-o force` overwriting anything already on the destination.

```console
:: On or against the SOURCE
Printbrm.exe -b -s \\OldPrintServer -f \\fileserver\share\printers.printerExport

:: On or against the DESTINATION
Printbrm.exe -r -s \\NewPrintServer -f \\fileserver\share\printers.printerExport -o force
```
Validate immediately with `Get-Printer -ComputerName NewPrintServer`, then proceed to Phase 4 (cutover) once satisfied.

**Rollback:** re-run the restore is not itself reversible against the destination's prior state — but since the source was never touched, "rollback" here just means abandoning the destination and continuing to serve from the source, which was never interrupted.

</details>

<details><summary>Playbook 2 — Driver modernization during migration (Jan 2026 legacy-driver landscape)</summary>

For any migration landing on Windows Server 2025+ or serving Windows 11 24H2+ clients, treat driver currency as a first-class migration task, not an afterthought.

```console
:: 1. Backup WITHOUT embedding old driver binaries
Printbrm.exe -b -nobin -s \\OldPrintServer -f printers.printerExport

:: 2. On the destination, install CURRENT vendor drivers for every affected model
:: (obtained from the vendor directly — do not rely on Windows Update for legacy models)

:: 3. Build BrmConfig.xml with a <DriverMap> entry per old→new driver pair

:: 4. Restore using the config file
Printbrm.exe -r -c BrmConfig.xml -f printers.printerExport -o force
```
Where no current vendor driver exists for a given model at all, this is the natural decision point to retire that specific queue onto the Microsoft IPP Class Driver (if the printer is IPP-Everywhere/Mopria-capable) rather than migrating a driver that has no future support runway.

**Rollback:** the original backup (taken with `-nobin`) is non-destructive and can be re-applied with a different `BrmConfig.xml` (or none at all) at any time before cutover.

</details>

<details><summary>Playbook 3 — Cross-domain migration</summary>

Queue-level ACLs referencing SIDs from a domain the destination doesn't trust are meaningless (and can produce confusing "orphaned SID" display artifacts) on the new domain.

```console
Printbrm.exe -r -noacl -f printers.printerExport -o force
```
`-noacl` strips ACLs from the print queues on restore; the queues then inherit the destination print server's own default permissions instead. Plan to explicitly re-apply any custom queue-level permissions the business actually needs post-restore, since `-noacl` is a clean-slate operation, not a translation.

**Rollback:** N/A — this only affects how permissions are set on the destination, the source is untouched.

</details>

<details><summary>Playbook 4 — Selective restore (only some printers from a full backup)</summary>

For migrating a subset of queues from a server backup that covers more than what's moving.

```console
:: 1. Export the full source
Printbrm.exe -b -s \\OldPrintServer -f full-export.printerExport

:: 2. Unpack to a working folder instead of restoring directly
Printbrm.exe -r -d C:\Temp\PrintMigrationWork -f full-export.printerExport

:: 3. Manually edit the unpacked XML manifests (BrmPrinters, etc.) to remove
::    entries for printers that should NOT move

:: 4. Repack the edited folder into a new backup file
Printbrm.exe -b -d C:\Temp\PrintMigrationWork -f selective-export.printerExport

:: 5. Restore the trimmed file to the destination
Printbrm.exe -r -f selective-export.printerExport -o force
```

**Rollback:** N/A — the source was only ever exported from, never modified; discard the working folder and start over if the manual edit was wrong.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects print server migration readiness/evidence for escalation or handoff.
.DESCRIPTION
    Read-only. Gathers role state, Print$/Remote Registry prerequisites, printer
    inventory with migration-eligibility flags (local-bus/PnP/LPR), driver names,
    and recent PrintBRM/PrintService event log entries. Run on SOURCE, DESTINATION,
    or both.
#>
[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME
)

Write-Host "=== Print Server Migration Evidence: $ComputerName ===" -ForegroundColor Cyan

Write-Host "`n-- Role State --" -ForegroundColor Yellow
Get-WindowsFeature -Name Print-Server -ComputerName $ComputerName -ErrorAction SilentlyContinue |
    Select-Object Name, Installed

Write-Host "`n-- Print`$ Share --" -ForegroundColor Yellow
try {
    Invoke-Command -ComputerName $ComputerName -ScriptBlock { Get-SmbShare -Name "Print$" -ErrorAction SilentlyContinue } |
        Select-Object Name, Path
} catch {
    Write-Warning "Could not query Print`$ share remotely: $($_.Exception.Message)"
}

Write-Host "`n-- Remote Registry Service --" -ForegroundColor Yellow
Get-Service -ComputerName $ComputerName -Name RemoteRegistry -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType

Write-Host "`n-- Printer Inventory + Migration Eligibility --" -ForegroundColor Yellow
$printers = Get-Printer -ComputerName $ComputerName -ErrorAction SilentlyContinue
$printers | ForEach-Object {
    [PSCustomObject]@{
        Name          = $_.Name
        PortName      = $_.PortName
        DriverName    = $_.DriverName
        Shared        = $_.Shared
        Published     = $_.Published
        LocalBusOrPnP = ($_.PortName -match "^(USB|LPT|COM)")
        LikelyLPR     = ($_.PortName -match "LPR")
    }
} | Format-Table -AutoSize

Write-Host "`n-- Recent PrintService/PrintBRM Events --" -ForegroundColor Yellow
foreach ($log in @("Microsoft-Windows-PrintService/Admin","Microsoft-Windows-PrintBRM/Admin")) {
    Write-Host "  [$log]"
    Get-WinEvent -ComputerName $ComputerName -LogName $log -MaxEvents 10 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, Message |
        Format-Table -Wrap
}

Write-Host "`n=== End Evidence Pack ===" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Printbrm.exe -b -s \\server -f file.printerExport` | Backup/export a print server |
| `Printbrm.exe -b -nobin -s \\server -f file.printerExport` | Backup without driver binaries (for a driver-substitution restore) |
| `Printbrm.exe -r -s \\server -f file.printerExport -o force` | Restore/import, overwriting existing objects |
| `Printbrm.exe -r -c BrmConfig.xml -f file.printerExport -o force` | Restore with a DriverMap config (modernize drivers during restore) |
| `Printbrm.exe -r -noacl -f file.printerExport -o force` | Restore stripping queue ACLs (cross-domain migrations) |
| `Printbrm.exe -r -lpr2tcp -f file.printerExport -o force` | Restore, converting LPR ports to standard TCP/IP ports |
| `Printbrm.exe -Q -F file.printerExport` | Query/validate a backup file without restoring anything |
| `Printbrm.exe -r -d <folder> -f file.printerExport` | Unpack a backup to a folder for manual editing |
| `Printbrm.exe -b -d <folder> -f file.printerExport` | Repack an edited folder into a new backup file |
| `Get-Printer -ComputerName <server>` | List printers/queues, driver, status, shared state |
| `Get-Printer \| Where PortName -match "USB\|LPT\|COM"` | Find printers that WON'T migrate (local bus/PnP) |
| `Get-WindowsFeature -Name Print-LPD-Print-Server-Fixed-Port` | Check for the LPR Port Monitor feature |
| `Get-SmbShare -Name "Print$"` | Confirm the PrintBRM driver-store share exists |
| `Get-Service -Name RemoteRegistry` | Confirm the prerequisite service for remote operations |
| `Set-Printer -Published $false` | Unpublish from AD DS (source, before rename) |
| `Rename-Computer -NewName <name> -Restart` | Execute the cutover rename sequence |

---

## 🎓 Learning Pointers

- **PrintBRM's design philosophy is "inventory everything, restore only what's structurally possible."** Understanding WHY local-bus and plug-and-play printers appear in the backup but can't be restored (there's no virtual USB/LPT bus on the destination to reattach them to) turns what looks like a tool bug into an expected, plannable limitation. [MS Docs: Migrate Print and Document Services](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/jj134150(v=ws.11))

- **The January 2026 legacy printer driver change is a genuine inflection point for this topic, not a minor footnote.** Prior to it, "the driver will just install from Windows Update" was a safe assumption during restore; that assumption now fails silently for older V3/V4 models on Windows Server 2025+/Windows 11 24H2+ destinations. Build driver-currency verification into Phase 1 of every migration going forward, not as a reactive fix. (Reported via industry coverage of Microsoft's driver publishing policy — see Petri's Feb 2026 writeup for the announced timeline; no single consolidated MS Learn landing page exists for this specific policy as of this run.)

- **The rename-based cutover only works because client connections are a literal UNC string, not a resolved/abstracted reference.** This is the same underlying reason server name changes are disruptive everywhere in Windows networking (SMB shares, RDP shortcuts, mapped drives) — print server migration just makes the mechanism unusually visible because the fix (matching names exactly) is baked into the documented procedure rather than being a workaround.

- **Rollback has a hard architectural cutoff, not a soft one.** "Can we still roll back?" has an exact, checkable answer: has source retirement (queue deletion, driver removal, hardware pull) started? Before that point it's a five-minute rename; after it, there is no partial undo — only a fresh migration. Confirm this explicitly with the customer/stakeholders before beginning Phase 4.

- **This tool and Storage Migration Service solve the same class of problem (decommissioning old server hardware) for two completely disjoint feature sets.** A single legacy box acting as both a file server and print server needs BOTH `StorageMigrationService-A.md`'s workflow and this one — running one does not imply progress on the other, and there's no combined tool that does both.

- **Only printer-queue permissions travel with a migration — everything else about "who can do what" on that server needs a manual audit.** System-level permissions, custom local group memberships used for print administration, and any non-queue-scoped delegation are explicitly out of scope for PrintBRM by design, not an oversight to chase down as a bug.
