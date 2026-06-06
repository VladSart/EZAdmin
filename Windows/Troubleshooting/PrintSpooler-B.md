# Print Spooler — Hotfix Runbook (Mode B: Ops)
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

Run these first — 60 seconds to understand the situation:

```powershell
# 1. Spooler service state
Get-Service -Name Spooler | Select-Object Name, Status, StartType

# 2. Queue depth — stuck jobs are the #1 cause of spooler crashes
Get-PrintJob -PrinterName * -ErrorAction SilentlyContinue | Select-Object PrinterName, JobStatus, Document, UserName

# 3. Spooler event log — last 10 errors
Get-WinEvent -LogName System -MaxEvents 100 |
  Where-Object { $_.ProviderName -eq 'Print.PrintFilterPipelinesvc' -or $_.ProviderName -eq 'Spooler' } |
  Select-Object TimeCreated, Id, Message -First 10

# 4. Driver integrity check — corrupt/unsigned drivers crash the spooler
Get-PrinterDriver | Select-Object Name, PrinterEnvironment, DriverVersion, InfPath

# 5. Spool folder size — full folder = spooler stops accepting jobs
(Get-ChildItem -Path "$env:SystemRoot\System32\spool\PRINTERS" -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
```

| Result | Action |
|--------|--------|
| Spooler Stopped / StartType Manual | → Fix 1: Restart & set to Automatic |
| Print jobs stuck (JobStatus = Deleting/Error) | → Fix 2: Clear stuck queue |
| EventID 7031 / 7034 in System log | → Spooler crashing — Fix 3: Driver isolation |
| Driver InfPath missing or driver very old | → Fix 4: Remove/reinstall driver |
| Spool folder > 500 MB | → Fix 2: Clear spool folder |
| Spooler starts but stops after <60s | → Fix 3 or Fix 5 (third-party driver) |

---
## Dependency Cascade

<details><summary>What must be true for printing to work</summary>

```
Hardware / Network
    └── Print Server (if shared) or Direct-IP printer
            └── Printer Driver (kernel-mode or user-mode)
                    └── Print Spooler Service (Spooler)
                            ├── Remote Procedure Call (RpcSs)    [hard dependency]
                            ├── DCOM Server Process Launcher      [hard dependency]
                            └── Print Filter Pipeline (optional)
                                    └── XPS Document Writer / PDF
                                            └── User Print Job
```

**Common single-point failures:**
- Driver in kernel mode → one bad driver takes down ALL printers
- Spool folder on a full volume → spooler silently rejects new jobs
- PrintNightmare mitigations (Point and Print disabled) → shared printer drivers can't install
- Stale GPO: `Limits print driver installation to Administrators` → users can't add drivers

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the spooler is healthy**
```powershell
Get-Service Spooler | Select-Object Status, StartType
```
- Expected: `Running`, `Automatic`
- If `Stopped` or `Manual` → go to Fix 1

**Step 2 — Check for stuck jobs**
```powershell
Get-PrintJob -PrinterName * -ErrorAction SilentlyContinue
```
- Expected: empty or jobs with `Normal` status
- If jobs show `Deleting`, `Error`, or `Retained` → go to Fix 2

**Step 3 — Check event log for crash pattern**
```powershell
Get-WinEvent -LogName System -MaxEvents 50 |
  Where-Object { $_.Id -in (7031,7034,7036) -and $_.Message -match 'Print' } |
  Format-List TimeCreated, Message
```
- EventID 7031: Service terminated unexpectedly — indicates crash loop
- If crash loop → Fix 3 (driver isolation)

**Step 4 — Identify crashing driver (if crash loop)**
```powershell
# Check for kernel-mode drivers (these are the crashers)
Get-PrinterDriver | Where-Object { $_.PrintProcessor -ne 'winprint' -or $_.InfPath -notmatch 'ntprint' } |
  Select-Object Name, PrinterEnvironment, PrintProcessor, DriverVersion
```
- Any driver with a third-party PrintProcessor or very old DriverVersion is a suspect
- If found → Fix 4 (remove driver)

**Step 5 — Validate spool folder**
```powershell
$spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
Get-ChildItem $spoolPath -Recurse | Select-Object Name, Length, LastWriteTime
```
- Expected: empty or only current in-progress jobs
- Any `.SHD` / `.SPL` files from yesterday or older → go to Fix 2

---
## Common Fix Paths

<details><summary>Fix 1 — Restart spooler and set to Automatic</summary>

```powershell
# Restart and re-enable the service
Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
Set-Service -Name Spooler -StartupType Automatic
Start-Service -Name Spooler
Get-Service Spooler | Select-Object Status, StartType
```

**Validate:** `Status = Running`. Test print a document immediately.  
**Rollback:** Not needed — this is non-destructive.  
**If it stops again within 5 minutes:** move to Fix 3 (driver crash loop).

</details>

<details><summary>Fix 2 — Clear stuck print queue</summary>

```powershell
# Stop spooler, clear queue, restart
Stop-Service -Name Spooler -Force
Start-Sleep -Seconds 3

# Delete all spool files
Remove-Item -Path "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue

# Restart
Start-Service -Name Spooler
Get-Service Spooler | Select-Object Status

# Verify queue is empty
Get-PrintJob -PrinterName * -ErrorAction SilentlyContinue | Measure-Object
```

**Validate:** Queue count = 0, Spooler = Running.  
**Note:** Clearing the queue deletes all pending print jobs — warn the user. Documents are NOT lost on disk, just the queued print requests.  
**Rollback:** None available — jobs must be re-submitted by users.

</details>

<details><summary>Fix 3 — Enable driver isolation (prevent driver crashes from killing spooler)</summary>

Driver isolation runs each driver in a separate user-mode process. Prevents one bad driver from crashing all printing.

```powershell
# Set all installed drivers to isolated mode
Get-PrinterDriver | ForEach-Object {
    $driverName = $_.Name
    try {
        Set-PrinterDriver -Name $driverName -PrinterEnvironment $_.PrinterEnvironment
        # Use the registry method as Set-PrinterDriver doesn't expose isolation directly
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Drivers\Version-3\$driverName"
        if (Test-Path $key) {
            Set-ItemProperty -Path $key -Name "PrintDriverIsolationAllowed" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        }
        Write-Host "Isolated: $driverName" -ForegroundColor Green
    } catch {
        Write-Host "Skipped: $driverName - $_" -ForegroundColor Yellow
    }
}

# Restart spooler to apply
Restart-Service Spooler -Force
```

**Alternative via Group Policy:**  
`Computer Configuration > Policies > Administrative Templates > Printers > Execute print drivers in isolated processes` → Enabled

**Validate:** Print a test page. If the driver was previously crashing the spooler, it will now crash only in isolation (spooler stays up).

</details>

<details><summary>Fix 4 — Remove and reinstall a suspect printer driver</summary>

Use when a specific driver is identified as the crash source.

```powershell
# List printers using the suspect driver
$suspectDriver = "<DriverName>"  # e.g. "HP LaserJet P3015 PCL6"
Get-Printer | Where-Object { $_.DriverName -eq $suspectDriver } | Select-Object Name

# Remove all printers using this driver first
Get-Printer | Where-Object { $_.DriverName -eq $suspectDriver } | Remove-Printer -ErrorAction SilentlyContinue

# Remove the driver (requires no printers still using it)
Stop-Service Spooler -Force
Start-Sleep -Seconds 3
Remove-PrinterDriver -Name $suspectDriver -ErrorAction SilentlyContinue
Start-Service Spooler

# Verify removal
Get-PrinterDriver | Where-Object { $_.Name -eq $suspectDriver }
```

**After removal:** Reinstall driver from vendor site or via `Add-PrinterDriver` / pnputil.  
**Rollback:** Export driver first: `Export-PrinterDriver -Name $suspectDriver -Path C:\Temp\` (if available).  
⚠️ **Destructive** — any printer using this driver will stop printing until re-added.

</details>

<details><summary>Fix 5 — PrintNightmare / Point and Print fix for shared printers</summary>

Since KB5005033 (Aug 2021), Windows blocks non-admin driver installs from print servers by default.  
Symptom: Users can't connect to shared printers, error 0x0000011B or "Operation could not be completed."

```powershell
# Check current Point and Print restrictions
$pnpKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
if (Test-Path $pnpKey) {
    Get-ItemProperty $pnpKey | Select-Object NoWarningNoElevationOnInstall, UpdatePromptSettings, RestrictDriverInstallationToAdministrators
} else {
    Write-Host "No Point and Print policy applied — using defaults (restricted)" -ForegroundColor Yellow
}

# OPTION A: Pre-approve specific print server (recommended)
# Set via GPO: Computer Config > Policies > Admin Templates > Printers > Point and Print Restrictions
# Add your print server to the approved servers list

# OPTION B: Allow but with elevation prompt (less permissive than removing restriction entirely)
Set-ItemProperty -Path $pnpKey -Name "NoWarningNoElevationOnInstall" -Value 0 -Type DWord
Set-ItemProperty -Path $pnpKey -Name "UpdatePromptSettings" -Value 0 -Type DWord

# Check package-aware printing on the print server
# Run on PRINT SERVER:
Get-Printer | Select-Object Name, Published, ShareName
```

**Best practice:** Use Universal Print or a package-aware print server rather than disabling PrintNightmare mitigations.  
**Rollback:** Re-enable restrictions via GPO. Do not set `RestrictDriverInstallationToAdministrators` to 0 in production without business justification.

</details>

---
## Escalation Evidence

```
## Print Spooler Escalation Pack

Ticket: [ticket number]
Date/Time: [timestamp]
Affected machine(s): [hostname(s)]
User(s) impacted: [UPNs]
Printer(s) affected: [printer names]

--- Service State ---
[paste: Get-Service Spooler output]

--- Event Log (last 10 print errors) ---
[paste: Get-WinEvent System errors for Spooler/Print]

--- Driver List ---
[paste: Get-PrinterDriver output]

--- Print Queue State ---
[paste: Get-PrintJob output]

--- Spool Folder Contents ---
[paste: Get-ChildItem $env:SystemRoot\System32\spool\PRINTERS output]

--- Steps Taken ---
[ ] Fix 1: Restart & set Automatic
[ ] Fix 2: Cleared stuck queue
[ ] Fix 3: Enabled driver isolation
[ ] Fix 4: Removed suspect driver
[ ] Fix 5: Point and Print policy reviewed

Current status after fixes: [running / still crashing / partially resolved]
Crash interval (if crash loop): [every X minutes]
```

---
## 🎓 Learning Pointers

- **Driver isolation is the right long-term fix.** Kernel-mode drivers (Version 3) run in-process with the spooler by default — one bad driver crashes everything. Enabling isolation per-driver is the defence. See: [Microsoft — Printer Driver Isolation](https://learn.microsoft.com/en-us/windows-hardware/drivers/print/printer-driver-isolation)

- **PrintNightmare changed the rules permanently.** Since Aug 2021, Point and Print restrictions are on by default. Understand [CVE-2021-34527](https://msrc.microsoft.com/update-guide/vulnerability/CVE-2021-34527) — you'll hit it on every new machine connecting to a legacy print server.

- **Universal Print eliminates the spooler dependency.** For clients on M365 E3+, Universal Print moves the queue to the cloud. No spooler = no spooler crashes. Worth proposing during MBRs. See: [Universal Print overview](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-whatis)

- **The spool folder is on the system drive by default.** If `C:\` is nearly full, the spooler silently stops accepting jobs. Consider moving it: `Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers" -Name DefaultSpoolDirectory`.

- **Stuck jobs with status "Deleting" are a kernel handle leak.** They cannot be deleted while the spooler is running — you must stop the service first before clearing `%SystemRoot%\System32\spool\PRINTERS`.

- **Check for PrintConfig.dll crashes.** EventID 1000 in Application log with `printconfig.dll` as the faulting module indicates an XPS rendering issue, often tied to a specific document type. Test with a plain-text print job to isolate.
