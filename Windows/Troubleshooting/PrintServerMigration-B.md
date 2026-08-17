# Print Server Migration — Hotfix Runbook (Mode B: Ops)
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

Run these first. Results tell you which fix path to take.

```powershell
# 1. Is the Print and Document Services role (and PrintBRM.exe) actually present on both boxes?
Get-WindowsFeature -Name Print-Server -ErrorAction SilentlyContinue | Select-Object Name, Installed
Test-Path "$env:SystemRoot\System32\spool\tools\PrintBRM.exe"

# 2. Is Print$ (the driver-store share PrintBRM needs) present, and is Remote Registry running?
#    Required on BOTH source and destination for any remote/network migration operation.
Get-SmbShare -Name "Print$" -ErrorAction SilentlyContinue | Select-Object Name, Path
Get-Service -Name RemoteRegistry | Select-Object Name, Status, StartType

# 3. Query a backup file WITHOUT restoring anything — cheapest way to confirm it's valid
#    before you trust it (or before opening a ticket about a "corrupt export").
& "$env:SystemRoot\System32\spool\tools\PrintBRM.exe" -Q -F <path\to\backup.printerExport>

# 4. Which printers on the SOURCE won't survive migration at all? (local bus / USB / plug-and-play)
#    These show up IN the backup but PrintBRM cannot restore them — flag before anyone panics.
Get-Printer | Where-Object { $_.PortName -match "^(USB|LPT|COM)" } | Select-Object Name, PortName, DriverName

# 5. Any LPR (Line Printer Remote) printers involved? Destination needs the LPR Port Monitor
#    feature installed FIRST — it is not present by default and LPD/LPR is deprecated.
Get-Printer | Get-PrinterPort | Where-Object { $_.PortNumber -eq 515 -or $_.Name -match "LPR" }
```

| If | Then |
|----|------|
| `PrintBRM.exe` missing on source or destination | Print and Document Services role not installed → **Fix 1** |
| `Print$` share missing, or Remote Registry not `Running` on either end | Prerequisite not met for a *remote* backup/restore → **Fix 1** |
| Restore succeeds but a printer shows a driver error / "no driver found" on a WS2025+ or Windows 11 24H2+ destination | Legacy V3/V4 driver blocked from Windows Update auto-publish since Jan 2026 → **Fix 2** |
| Restore fails specifically on a language monitor, source and destination are different CPU architectures (x86→x64) | Language monitor drivers are architecture-bound, not portable → **Fix 3** |
| A USB/LPT/local-bus or plug-and-play printer is "missing" after restore | Never actually migrated by design — shown in backup, not restorable → **Fix 4** |
| LPR printer restore fails outright | LPR Port Monitor feature not installed on the destination → **Fix 5** |
| Same printer shows twice in Active Directory / AD DS after cutover | Source wasn't unpublished before the rename step → **Fix 6** |
| Spooler service crashes or hangs mid-restore | A specific legacy/buggy driver is crashing spoolsv.exe during import → **Fix 7** |
| Clients can't print after cutover even though the wizard reported success | Two-phase rename sequence incomplete or done out of order → **Fix 8** |
| Need to undo a migration that's already underway | Only possible if source retirement hasn't started yet → **Fix 9** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Print and Document Services role installed on BOTH source and destination
  (PrintBRM.exe ships inside this role — %SystemRoot%\System32\spool\tools\)
        │
Print$ share present on BOTH ends (auto-created with the role)
Remote Registry service RUNNING on BOTH ends
  (only required when migrating over the network to a different computer —
   a local-only backup/restore on one box doesn't need this)
        │
BACKUP (-B) — PrintBRM exports queues, drivers, ports, forms, and per-queue
security to a single compressed .printerExport file:
   BrmPrinters (queue list) · BrmDrivers (driver binaries + manifest)
   BrmPorts · BrmForms · BrmLMons (language monitors) · BrmSpoolerAttrib
        │
   [OPTIONAL] Manual edit of the exported XML manifests via -D <folder>,
   or a BrmConfig.xml DriverMap to swap drivers on restore
        │
RESTORE (-R) — imports the file onto the destination
   Local bus (USB/LPT) and plug-and-play printers are shown in the backup
   but CANNOT be restored — they must be physically reconnected and re-shared
   Cross-architecture language monitor restores fail by design (arch-bound)
        │
Destination printers online, queues verified, ACLs (queue-level only —
NOT system/local custom permissions) confirmed against the source
        │
[OPTIONAL] CUTOVER — two-phase rename so client UNC paths (\\servername\
printer) keep working with ZERO client-side reconfiguration:
   1. Unpublish source from AD DS (if published) BEFORE any rename
   2. Rename destination to a temporary name (e.g. SRV_NEW)
   3. Rename source away (e.g. SRV_OLD) — retire per normal decommission policy
   4. Rename destination to the source's ORIGINAL name
   5. Publish destination to AD DS (if desired) only AFTER step 4
   Rollback is only possible before source retirement (queue deletion,
   driver removal, hardware pulled) begins — after that, restart from scratch
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the role and PrintBRM.exe exist on both machines before touching anything else:**
```powershell
Get-WindowsFeature -Name Print-Server | Select-Object Name, Installed
```
If `Installed = False` on either end, stop — every subsequent step depends on this role.

**2. Confirm `Print$` and Remote Registry on both ends for a REMOTE operation:**
```powershell
Get-SmbShare -Name "Print$"
Get-Service -Name RemoteRegistry | Select-Object Status
```
Both required only when the source and destination are different computers. A local export→copy→local import workflow doesn't need Remote Registry running.

**3. Validate the backup file itself before restoring — this never modifies anything:**
```powershell
& "$env:SystemRoot\System32\spool\tools\PrintBRM.exe" -Q -F C:\Temp\printers.printerExport
```
A clean query output listing printers/drivers/ports confirms the CAB isn't corrupt. If this fails, re-export from the source rather than debugging a restore against a bad file.

**4. Find the RIGHT event log — the location depends on what's already installed on the destination:**
```powershell
# Managing migration remotely from an admin workstation, OR destination has
# NO Print and Document Services role yet:
Get-WinEvent -LogName "Microsoft-Windows-PrintService/Admin" -MaxEvents 30 -ErrorAction SilentlyContinue

# Destination ALREADY has the role installed:
Get-WinEvent -LogName "Microsoft-Windows-PrintBRM/Admin" -MaxEvents 30 -ErrorAction SilentlyContinue
```
Checking the wrong one is the single most common reason an engineer says "there's nothing in the event log" when there is — PrintBRM logs to a different channel than general print service events depending on install state.

**5. Inventory anything that will NOT survive migration before anyone is surprised:**
```powershell
Get-Printer | Where-Object { $_.PortName -match "^(USB|LPT|COM)" } | Select-Object Name, PortName
```
These print correctly (they're local, after all) but PrintBRM can only show them in the backup manifest — it never restores local-bus or true plug-and-play printers to the destination.

**6. Confirm the printer queue-level driver actually matches what you expect on the destination:**
```powershell
Get-Printer -ComputerName <destination> | Select-Object Name, DriverName, PrinterStatus
```
A driver error here on a Windows Server 2025 or Windows 11 24H2+ destination is very often the January 2026 legacy-driver-publishing change (Fix 2), not a corrupt restore.

**7. Only after cutover: print an actual test job from an EXISTING client connection**, not a brand-new one:
```powershell
# From a client that already had a mapped connection to the OLD server name
Get-Printer | Where-Object { $_.ComputerName -eq "<original server name>" } | Out-Printer
```
A fresh connection tells you the destination works. An existing connection tells you the cutover actually preserved the client-side UNC path — the only thing that matters for a zero-touch migration.

---

## Common Fix Paths

<details><summary>Fix 1 — Print$ share missing or Remote Registry not running (network operation fails / access denied)</summary>

**Symptom:** `PrintBrm.exe -b -s \\server -f file.printerExport` fails with an access or connectivity error, even though the account running it is a local admin on the target.

```powershell
# Confirm/enable Remote Registry on BOTH source and destination
Get-Service -Name RemoteRegistry | Set-Service -StartupType Automatic
Start-Service -Name RemoteRegistry

# Confirm the Print$ share exists (it's auto-created by the Print and Document
# Services role — if missing, the role's driver-store component is broken)
Get-SmbShare -Name "Print$"
```
If `Print$` is genuinely absent despite the role showing installed, repair the role: `Uninstall-WindowsFeature Print-Server` then `Install-WindowsFeature Print-Server -IncludeManagementTools`, then re-check.

**Rollback:** N/A — enabling a service and confirming a share isn't destructive. If Remote Registry was intentionally disabled by security policy, re-disable it once the migration operation completes.

</details>

<details><summary>Fix 2 — Driver error / "no driver found" on a WS2025+ or Windows 11 24H2+ destination</summary>

**Symptom:** Printers restore, queues exist, but the destination reports a driver error, or the driver silently fails to install because Windows Update won't auto-fetch it.

Since January 15, 2026, Windows Update no longer auto-publishes NEW third-party V3/V4 legacy printer driver packages for Windows 11 and Windows Server 2025+ — a driver that used to install itself from Windows Update during a `PrintBrm -R` restore may no longer be fetchable that way, even though the driver itself hasn't changed on the vendor's side.

```console
:: Step 1 — back up from the SOURCE without embedding the old driver binaries
Printbrm.exe -b -nobin -s \\OldPrintServer -f printers.printerExport

:: Step 2 — on the NEW destination, manually install the current vendor driver
:: (from the vendor's own package, not Windows Update) for each affected model FIRST

:: Step 3 — create a BrmConfig.xml mapping the old driver name to the new one
```
```xml
<BrmConfig>
  <PLUGINS></PLUGINS>
  <LanguageMonitors></LanguageMonitors>
  <DriverMap>
    <DRV old="OldDriverName" new="NewDriverName"/>
  </DriverMap>
</BrmConfig>
```
```console
:: Step 4 — restore using the config file, forcing overwrite
Printbrm.exe -r -c BrmConfig.xml -f printers.printerExport -o force
```
Where a current vendor driver isn't available at all, evaluate moving that queue to the Microsoft IPP Class Driver / Universal Print instead of chasing a legacy driver package — see `M365/UniversalPrint/Universal-Print-A.md`.

**Rollback:** Restore again from the ORIGINAL backup (with binaries, no `-nobin`) if the vendor driver substitution doesn't work — this doesn't touch the source.

</details>

<details><summary>Fix 3 — Restore fails on a language monitor (cross-architecture migration)</summary>

**Symptom:** Restore reports an error specifically tied to a language monitor when migrating from an x86 source to an x64 destination (or vice versa).

This is expected — language monitor driver files are architecture-bound and PrintBRM cannot translate them. The printer queue itself still restores; only the language monitor component fails.

```powershell
# On the destination, manually install/reinstall the STANDARD driver for the
# affected architecture — this recovers the printer without the language monitor
Add-PrinterDriver -Name "<DriverName>" -InfPath "<path\to\destination-arch\driver.inf>"
```

**Rollback:** N/A — this is an additive manual fix, nothing to undo.

</details>

<details><summary>Fix 4 — USB/LPT/local-bus or plug-and-play printer "missing" after migration</summary>

**Symptom:** A printer that worked fine on the source doesn't appear on the destination, even though the migration reported success.

This is not a failure — local bus (USB, LPT) and true plug-and-play printers are explicitly unsupported for automated migration. They appear in the PrintBRM backup manifest (so the tool "sees" them) but are never restored.

```powershell
# On the destination: physically connect the printer, let Windows install it,
# then re-share it manually
Set-Printer -Name "<PrinterName>" -Shared $true -ShareName "<ShareName>"
```
Verify the printer's name hasn't changed after re-sharing, and test the shared connection from a client.

**Rollback:** N/A — this is the expected manual completion step, not a change to revert.

</details>

<details><summary>Fix 5 — LPR printer restore fails</summary>

**Symptom:** Restore errors specifically on an LPR (Line Printer Remote) printer or port.

```powershell
# Install the LPR Port Monitor feature on the DESTINATION before restoring
Install-WindowsFeature -Name Print-LPD-Print-Server-Fixed-Port -ErrorAction SilentlyContinue
# Or via Server Manager: Add Roles and Features → Features → LPR Port Monitor
```
LPD/LPR has been deprecated since Windows Server 2012 and is a good candidate to retire during this migration rather than carry forward — most modern printers support standard TCP/IP (Port 9100) ports instead. If retiring it now isn't feasible, `-lpr2tcp` on restore converts LPR ports to standard TCP/IP ports automatically:
```console
Printbrm.exe -r -lpr2tcp -f printers.printerExport -o force
```

**Rollback:** N/A — installing a feature or converting a port type isn't destructive to the source.

</details>

<details><summary>Fix 6 — Duplicate printer appears in Active Directory after cutover</summary>

**Symptom:** The same shared printer shows twice when browsing AD DS for printers, one instance pointing at the old server name.

The source was still published to AD DS when the destination was also published (or renamed into the source's old identity).

```powershell
# On the SOURCE, before any rename — unpublish everything
# (Print Management snap-in: select all printers → right-click → Remove from Directory)
Get-Printer | Where-Object { $_.Published } | Set-Printer -Published $false
```
Only re-publish on the destination (`Set-Printer -Published $true`, or "List in directory" in Print Management) AFTER the destination has been renamed to the source's original name — publishing too early, before the rename, is what causes the duplicate to appear in the first place.

**Rollback:** Re-publish/unpublish as needed — AD DS printer publication is non-destructive to the printer object itself.

</details>

<details><summary>Fix 7 — Spooler service crashes or hangs during restore</summary>

**Symptom:** `spoolsv.exe` crashes, restarts, or the restore appears to hang partway through importing drivers.

A specific legacy or poorly-behaved third-party driver is crashing the spooler process during import. Turn on print driver isolation so one bad driver can't take the whole spooler down, then retry:

```powershell
# Via Group Policy (Computer Configuration > Administrative Templates > Printers)
# Enable both settings:
#   "Execute print drivers in isolated processes"
#   "Override print driver execution compatibility setting reported by print driver"
gpupdate /force
```
Retry the restore after the policy applies. If it still crashes on the same specific printer, exclude that one printer from the batch restore and install its driver manually afterward.

**Rollback:** Re-disable the two GPO settings once the migration is complete if driver isolation isn't wanted long-term (it has a minor performance cost per print job and is usually left enabled going forward for the security benefit — see `PrintSpooler-A.md`'s PrintNightmare coverage).

</details>

<details><summary>Fix 8 — Clients can't print after cutover despite a "successful" migration</summary>

**Symptom:** All printers show correctly on the destination, but existing client print connections fail after the migration is declared complete.

The two-phase rename sequence wasn't completed, or was done out of order. Client machines have an existing UNC connection (`\\oldservername\printername`) baked into their print queue — the ONLY way to avoid touching every client is for the destination to end up with the exact original server name.

```powershell
# Confirm current names
$env:COMPUTERNAME   # run on both source and destination

# Correct order:
# 1. Unpublish source from AD DS (Fix 6)
# 2. Rename destination to a temporary name, e.g. PRINTSRV_NEW
Rename-Computer -NewName "PRINTSRV_NEW" -Restart
# 3. Rename source away, e.g. PRINTSRV_OLD, then retire per policy
Rename-Computer -NewName "PRINTSRV_OLD" -Restart
# 4. Rename destination to the ORIGINAL source name
Rename-Computer -NewName "PRINTSRV" -Restart
```
Print connections will fail for clients ONLY during the window between step 3 (source renamed away) and step 4 (destination renamed to match) — plan that window as the actual maintenance outage, not the whole migration.

**Rollback:** Rename the destination back to its temporary name and the source back to its original name — possible any time before source retirement (queue deletion, driver removal, hardware decommission) has started. See Fix 9.

</details>

<details><summary>Fix 9 — Need to roll back a migration already in progress</summary>

**Symptom:** Migration needs to be undone/paused after cutover has started.

Rollback is only possible if source retirement has **not yet begun** — that is, no print queues deleted, no driver reformats, no hardware removed from the source.

```powershell
# Rename the destination back to a non-conflicting temporary name
Rename-Computer -NewName "PRINTSRV_NEW" -Restart

# Rename the source back to its ORIGINAL pre-migration name
Rename-Computer -NewName "PRINTSRV" -Restart
```
Renaming both computers is the entire rollback — it typically completes in a few minutes plus reboot time. **Once source retirement has started, rollback is no longer possible; the only path forward is restarting the whole migration process from a fresh backup.**

**Rollback:** This fix path IS the rollback procedure.

</details>

---

## Escalation Evidence

```
=== Print Server Migration Failure — Ticket Evidence ===

Date/Time:                          _______________
Source print server:                _______________
Destination print server:           _______________
Migration phase that failed:        _______________  (Backup / Restore / Cutover)
Cross-architecture migration?:      _______________  (x86 source, x64 dest, or vice versa)

--- Commands Run ---
PrintBRM.exe present on both ends?:  _______________
Print$ share present on both ends?:  _______________
Remote Registry running on both?:    _______________
PrintBRM -Q query result on backup:  _______________
Correct event log checked (PrintService vs PrintBRM/Admin):  _______________
Destination driver name/status (Get-Printer):  _______________

--- Scenario ---
[ ] Backup/export fails
[ ] Restore/import fails — driver error
[ ] Restore/import fails — language monitor / cross-architecture
[ ] Local-bus/USB/plug-and-play printer "missing" post-migration
[ ] LPR printer restore fails
[ ] Duplicate printer in Active Directory after cutover
[ ] Spooler crash/hang during restore
[ ] Clients can't print after cutover (rename sequence)
[ ] Need to roll back an in-progress migration

--- Steps Taken ---
[ ] Verified Print and Document Services role + Print$ share + Remote Registry on both ends
[ ] Validated the backup file with PrintBRM -Q before restoring
[ ] Checked the correct event log for the destination's install state
[ ] Confirmed driver model / current vendor driver availability (Jan 2026 V3/V4 change)
[ ] Confirmed source retirement has/has not started (rollback window)
```

---

## 🎓 Learning Pointers

- **The January 2026 legacy printer driver change is now the single biggest new risk in a routine print server migration.** Since January 15, 2026, Windows Update no longer auto-publishes new third-party V3/V4 driver packages for Windows 11 and Windows Server 2025+, and industry reporting indicates Windows' driver-ranking logic is moving toward preferring the inbox IPP Class Driver going forward. A migration that "just worked" for a decade by letting Windows Update fetch the right driver on restore can now silently fail on modern destinations — plan to source current vendor drivers or a `-nobin` + `DriverMap` swap (Fix 2) BEFORE the migration window, not during it.

- **PrintBRM only migrates what it CAN migrate — local bus and plug-and-play printers were never in scope.** This surprises engineers who assume "it's in the backup file" means "it will be restored." Set expectations with the customer/end users before migration day, not after a help desk ticket about a missing receipt printer.

- **The event log location for migration errors depends on what's already installed on the destination — check the wrong one and you'll wrongly conclude "no errors occurred."** `Microsoft-Windows-PrintService/Admin` before the role exists there, `Microsoft-Windows-PrintBRM/Admin` after. PrintBRM.exe's own command-line error output is frequently more detailed than either log — don't skip it in favor of the GUI wizard alone.

- **The rename-based cutover is the whole trick for a zero-touch client migration.** Clients hold a UNC path (`\\servername\printer`), not an IP or GUID — the destination only becomes truly transparent to end users once it carries the exact original server name. Understanding this explains both why the outage window is so short (only between the two renames) and why rollback stops being possible the moment source retirement (queue deletion, driver removal) begins.

- **This is architecturally the print-specific sibling of Storage Migration Service, not the same tool.** SMS (`StorageMigrationService-B.md`) explicitly does not migrate print queues — it's file-server-focused. If a decommission project involves both a legacy file server AND a legacy print server on the same box, expect to run two separate tools with two separate playbooks, not one combined migration.

- **Universal Print is the alternative to ALL of this, not a variant of it.** If the actual goal is getting off on-premises print servers entirely rather than moving to a newer one, evaluate `M365/UniversalPrint/Universal-Print-A.md` before investing migration effort in a server that's slated for elimination anyway.
