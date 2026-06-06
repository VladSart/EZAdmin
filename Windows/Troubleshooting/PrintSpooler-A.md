# Print Spooler — Reference Runbook (Mode A: Deep Dive)
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
- Windows Print Spooler (spoolsv.exe) on Windows 10/11 and Windows Server 2019/2022
- Local printers, shared/networked printers via print server, and Universal Print-connected printers
- Intune-deployed printers (via scripts or Universal Print connector)
- PrintNightmare post-remediation environments (Aug 2021+)

**Does not cover:**
- macOS printing (see `macOS/` folder)
- Linux CUPS
- Printer hardware faults (see vendor documentation)
- Industrial/thermal label printers with proprietary Windows drivers (Zebra, Dymo — vendor-specific troubleshooting required)

**Assumptions:**
- Target machines are domain-joined or Entra-joined Windows 10 21H2+ or Windows 11
- Engineer has local admin or equivalent remote admin access
- If print server is involved, access to the server is assumed

---
## How It Works

<details><summary>Full architecture</summary>

### The Windows Print Architecture

Windows printing involves multiple layers. Understanding where failures occur saves diagnostic time.

```
User Application (Word, Chrome, etc.)
        |
        | GDI / XPS print call
        v
Win32 Print API (winspool.drv)
        |
        | IPC via LPC or named pipe
        v
Print Spooler Service (spoolsv.exe)
        |
        +--[Local printers]---> Print Router
        |                           |
        |                           v
        |                   Printer Driver (kernel-mode v3 or user-mode v4)
        |                           |
        |                           v
        |                   Print Processor (winprint.dll or custom)
        |                           |
        |                           v
        |                   Language Monitor (optional, e.g., pjlmon.dll)
        |                           |
        |                           v
        |                   Port Monitor (tcpmon.dll for TCP/IP, usbmon.dll for USB)
        |                           |
        |                           v
        |                   Physical Port → Printer Hardware
        |
        +--[Shared printers]--> Print Server (remote spoolsv.exe via RPC)
                                    |
                                    v
                            Same local path as above
```

### Key processes and DLLs

| Component | File | Role |
|-----------|------|------|
| Spooler Service | `spoolsv.exe` | Core service; manages queue and router |
| Spooler API | `winspool.drv` | User-space API called by apps |
| Print Router | `spoolss.dll` | Routes to local or remote queue |
| XPS Filter Pipeline | `xpssvcs.dll` | Converts XPS to printer language |
| Print Config | `printconfig.dll` | Renders print preferences UI |
| Port Monitor | `tcpmon.dll` | Manages TCP/IP port communication |
| Driver Store | `C:\Windows\System32\DriverStore\FileRepository` | Canonical driver source |

### Driver generations

| Version | Mode | Isolation | Notes |
|---------|------|-----------|-------|
| v3 (Type 3) | Kernel or User | Optional | Legacy; most crashes here |
| v4 (Type 4) | User only | Always isolated | No kernel mode; preferred |
| Package-aware | User | Always isolated | Required for Point and Print post-PrintNightmare |

### Spool file types

- `.SPL` — the actual print data (EMF, RAW, XPS depending on driver)
- `.SHD` — shadow file (job metadata: user, time, priority)
- Location: `%SystemRoot%\System32\spool\PRINTERS\`
- Both files must be present for a job to be visible in the queue

### How a print job flows (local printer)

1. App calls `StartDocPrinter()` via winspool.drv
2. Spooler writes `.SPL` and `.SHD` to spool folder
3. Print Router selects the driver
4. Driver renders job to printer language (PCL/PostScript/XPS)
5. Language monitor sends rendered output to port monitor
6. Port monitor sends to printer hardware
7. On success, spooler deletes `.SPL` and `.SHD`

**Failure at step 2:** Volume full, permissions on spool folder  
**Failure at step 4:** Driver crash, driver incompatibility  
**Failure at step 5-6:** Network timeout, printer offline, bad port config

</details>

---
## Dependency Stack

```
Physical Layer
    └── Printer Hardware (USB / TCP/IP / Wi-Fi)
            └── Port Monitor (tcpmon.dll / usbmon.dll / WSD)
                    └── Language Monitor (pjlmon.dll or vendor)
                            └── Printer Driver (v3 kernel/user or v4 user-mode)
                                    └── Print Processor (winprint or custom)
                                            └── Print Spooler (spoolsv.exe)
                                                    ├── RPC / DCOM (rpcss, DcomLaunch) [hard deps]
                                                    ├── Spool Folder (NTFS, requires free space)
                                                    └── Win32 Print API (winspool.drv)
                                                            └── User Application
```

**Hard dependencies that must be running:**
- `RpcSs` (Remote Procedure Call) — Spooler won't start without it
- `DcomLaunch` — Required for out-of-process driver hosting
- NTFS permissions on `%SystemRoot%\System32\spool\PRINTERS` — SYSTEM must have Full Control

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Spooler stops immediately after start | Driver crash (v3 kernel-mode) | EventID 7034, Application EventID 1000 with driver DLL |
| Jobs stuck in queue, won't delete | Spooler running but driver frozen; orphaned spool files | Stop spooler, clear PRINTERS folder |
| Error 0x0000011B connecting to shared printer | PrintNightmare GPO blocking driver install | Point and Print restrictions policy |
| Error 0x00000709 setting default printer | Registry permissions issue | `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Windows\Device` |
| "Operation failed" adding network printer | Firewall blocking SMB/RPC (135, 445, 49152-65535) | `Test-NetConnection` to print server |
| Spooler crash loop every ~5 min | Bad driver or PrintConfig.dll faulting on specific job type | AppCrash in Event Viewer, WER dumps |
| USB printer not detected | USB port monitor (usbmon.dll) issue or missing driver | Device Manager, `pnputil /enum-devices /class Printer` |
| Print jobs appear then disappear | Printer in "Delete on error" mode; job failing silently | Printer properties → Advanced → "Keep printed documents" temp |
| Users can print, admins can't (or vice versa) | Per-user printer settings conflict with machine-level GPO | `rundll32 printui.dll,PrintUIEntry /e /n <printername>` |
| Slow to print, high CPU during spooler render | v3 driver doing in-process EMF rendering | Switch to v4 driver; enable driver isolation |
| "Access Denied" when adding local printer | UAC / PrintNightmare: `RestrictDriverInstallationToAdministrators` = 1 | Registry / GPO |
| Printer offline (network printer always shows offline) | WSD monitor vs TCP/IP monitor mismatch | Delete and re-add as TCP/IP port |

---
## Validation Steps

**Step 1 — Service state and dependencies**
```powershell
Get-Service -Name Spooler, RpcSs, DcomLaunch | Select-Object Name, Status, StartType
```
Expected (good): All three `Running`. Spooler `Automatic`.  
Bad: Any dependency `Stopped` → fix that first.

**Step 2 — Spool folder health**
```powershell
$folder = "$env:SystemRoot\System32\spool\PRINTERS"
$acl = Get-Acl $folder
$acl.Access | Select-Object IdentityReference, FileSystemRights, AccessControlType
Get-Item $folder | Select-Object FullName
(Get-ChildItem $folder -Recurse | Measure-Object Length -Sum).Sum / 1MB
```
Expected (good): SYSTEM has FullControl; folder accessible; size < 50 MB in normal operation.  
Bad: Permissions missing → `icacls "$env:SystemRoot\System32\spool\PRINTERS" /grant SYSTEM:(OI)(CI)F`

**Step 3 — Driver inventory**
```powershell
Get-PrinterDriver | Select-Object Name, PrinterEnvironment, DriverVersion, InfPath |
  Sort-Object PrinterEnvironment | Format-Table -AutoSize
```
Expected (good): InfPath points to valid `.inf` file; DriverVersion is current.  
Bad: Empty InfPath or version from pre-2018 for generic drivers.

**Step 4 — Crash evidence**
```powershell
# Application crash log
Get-WinEvent -LogName Application -MaxEvents 200 |
  Where-Object { $_.Id -eq 1000 -and $_.Message -match 'spoolsv|printconfig|spoolss' } |
  Select-Object TimeCreated, Message -First 5 | Format-List

# System service failure log
Get-WinEvent -LogName System -MaxEvents 100 |
  Where-Object { $_.Id -in (7031, 7034) -and $_.Message -match 'Print' } |
  Select-Object TimeCreated, Id, Message -First 5 | Format-List
```
Expected (good): No matching events.  
Bad: EventID 1000 with specific DLL → that DLL is the crashing component.

**Step 5 — Active print queue**
```powershell
Get-Printer | ForEach-Object {
    $printer = $_.Name
    $jobs = Get-PrintJob -PrinterName $printer -ErrorAction SilentlyContinue
    if ($jobs) { $jobs | Select-Object @{N='Printer';E={$printer}}, Document, JobStatus, UserName, TotalPages }
}
```
Expected (good): Empty or jobs with `Normal` status completing quickly.  
Bad: Jobs in `Retained`, `Deleting`, `Error` state.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Service and dependency validation (2 min)

```powershell
# Full service dependency check
$deps = @('Spooler', 'RpcSs', 'DcomLaunch', 'PlugPlay')
foreach ($svc in $deps) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    Write-Host "$svc`: $($s.Status) [$($s.StartType)]" -ForegroundColor $(if ($s.Status -eq 'Running') {'Green'} else {'Red'})
}
```

If RpcSs or DcomLaunch are stopped, fix those first — Spooler cannot run without them.

### Phase 2 — Event log pattern matching (3 min)

```powershell
# Identify the exact crash component
$events = Get-WinEvent -LogName Application, System -MaxEvents 500 |
  Where-Object { $_.Message -match 'print|spooler|spoolsv' -and $_.Level -in (1,2) }
$events | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 10 Count, Name
$events | Where-Object { $_.Id -eq 1000 } | Select-Object TimeCreated, Message -First 3 | Format-List
```

Key EventIDs to look for:
- **1000** (Application Error): Faulting module name tells you the exact DLL causing the crash
- **7031** (System): Service terminated unexpectedly — with restart count
- **7034** (System): Service terminated unexpectedly (no restart configured)
- **372** (Print-PrintFilterPipelinesvc): XPS filter pipeline crash — usually a document format issue

### Phase 3 — Driver isolation testing (5 min)

If a crash is identified but you can't remove the driver immediately (business-critical printer), enable isolation:

```powershell
# Check current isolation settings
Get-PrinterDriver | Select-Object Name, @{
    N='IsolationMode';
    E={(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Drivers\Version-3\$($_.Name)" -Name PrintDriverIsolationAllowed -ErrorAction SilentlyContinue).PrintDriverIsolationAllowed}
}

# Enable isolation for all v3 drivers via registry
$envPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Drivers\Version-3"
Get-ChildItem $envPath | ForEach-Object {
    Set-ItemProperty -Path $_.PSPath -Name PrintDriverIsolationAllowed -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Host "Isolated: $($_.PSChildName)" -ForegroundColor Green
}

Restart-Service Spooler -Force
```

### Phase 4 — PrintNightmare policy audit (5 min)

```powershell
# Check all relevant PrintNightmare registry values
$keys = @{
    'PointAndPrint' = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
    'PrinterDriverExclusion' = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Providers\Client Side Rendering Print Provider'
    'PackagePointAndPrint' = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PackagePointAndPrint'
}

foreach ($name in $keys.Keys) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    if (Test-Path $keys[$name]) {
        Get-ItemProperty $keys[$name]
    } else {
        Write-Host "(not configured — defaults apply)" -ForegroundColor Yellow
    }
}
```

Key values and their meaning:
- `NoWarningNoElevationOnInstall = 1` — Installs silently (reduces security)
- `UpdatePromptSettings = 0` — No prompt on driver update
- `RestrictDriverInstallationToAdministrators = 1` — **This is the PrintNightmare fix** — blocks non-admin driver install

### Phase 5 — Spool folder and permissions (2 min)

```powershell
$spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"

# Permission audit
icacls $spoolPath

# Space audit
$drive = Split-Path -Qualifier $env:SystemRoot
$disk = Get-PSDrive ($drive.TrimEnd(':'))
Write-Host "Free space on $drive`: $([math]::Round($disk.Free/1GB, 2)) GB"

# Orphaned spool files
$orphans = Get-ChildItem $spoolPath | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) }
Write-Host "Orphaned spool files: $($orphans.Count)"
$orphans | Select-Object Name, Length, LastWriteTime
```

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full spooler reset (safe for all cases)</summary>

```powershell
# Safe full reset — stops service, clears queue, restarts
Write-Host "Stopping Print Spooler..." -ForegroundColor Yellow
Stop-Service Spooler -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# Verify stopped
if ((Get-Service Spooler).Status -ne 'Stopped') {
    Stop-Process -Name spoolsv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# Clear spool folder
$spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
$files = Get-ChildItem $spoolPath -ErrorAction SilentlyContinue
Write-Host "Clearing $($files.Count) spool files..."
$files | Remove-Item -Force -ErrorAction SilentlyContinue

# Set to Automatic and start
Set-Service Spooler -StartupType Automatic
Start-Service Spooler
Start-Sleep -Seconds 3

# Verify
$svc = Get-Service Spooler
Write-Host "Spooler status: $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') {'Green'} else {'Red'})
Get-PrintJob -PrinterName * -ErrorAction SilentlyContinue | Measure-Object | Select-Object Count
```

**Rollback:** None needed — this only removes pending jobs.  
**Impact:** All queued print jobs are lost and must be resubmitted.

</details>

<details><summary>Playbook 2 — Remove and clean a specific problematic driver</summary>

```powershell
param (
    [string]$DriverName = "<DriverNameHere>"
)

Write-Host "Target driver: $DriverName" -ForegroundColor Cyan

# List all printers using this driver
$affectedPrinters = Get-Printer | Where-Object { $_.DriverName -eq $DriverName }
Write-Host "Printers using this driver: $($affectedPrinters.Count)"
$affectedPrinters | Select-Object Name, PortName, Shared

# Confirm removal
$confirm = Read-Host "Remove all $($affectedPrinters.Count) printer(s) and driver? (yes/no)"
if ($confirm -ne 'yes') { Write-Host "Aborted."; return }

# Remove printers first
$affectedPrinters | ForEach-Object {
    Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
    Write-Host "Removed printer: $($_.Name)" -ForegroundColor Yellow
}

# Stop spooler and remove driver
Stop-Service Spooler -Force
Start-Sleep -Seconds 3
Remove-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue

# Also remove from driver store if desired
$driverStore = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" -Filter "*.inf" -Recurse |
    Select-String -Pattern [regex]::Escape($DriverName) -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Filename -Unique
if ($driverStore) {
    Write-Host "Driver store entries found: $driverStore" -ForegroundColor Yellow
    # pnputil /delete-driver <inf> /uninstall  ← run manually after verifying
}

Start-Service Spooler
Write-Host "Done. Reinstall the printer with an updated driver." -ForegroundColor Green
```

**Rollback:** Reinstall driver from vendor site. If you have a `.inf` from the driver store, run `pnputil /add-driver <inf> /install`.  
⚠️ **Impact:** All printers using this driver stop printing until driver is reinstalled.

</details>

<details><summary>Playbook 3 — Repair spool folder permissions</summary>

Occasionally permissions on the spool folder are stripped by security hardening scripts or ransomware activity.

```powershell
$spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"

Write-Host "Current ACL:" -ForegroundColor Cyan
icacls $spoolPath

# Restore default permissions
# SYSTEM: Full Control (inherited to children)
# Administrators: Full Control
# Creator Owner: Full Control (subfolders and files only)
icacls $spoolPath /grant "SYSTEM:(OI)(CI)F" /grant "Administrators:(OI)(CI)F" /grant "CREATOR OWNER:(OI)(CI)(IO)F"
icacls $spoolPath /inheritance:r  # Remove inherited, keep explicit

Write-Host "Permissions restored. Restarting spooler..." -ForegroundColor Green
Restart-Service Spooler -Force
icacls $spoolPath  # Verify
```

**Rollback:** The original permissions are typically what's above — if you're restoring these, there's no worse state to go back to.

</details>

<details><summary>Playbook 4 — Migrate from WSD port to TCP/IP port (fixes "always offline" network printers)</summary>

WSD (Web Services for Devices) ports auto-discover printers but are unreliable on enterprise networks with port filtering.

```powershell
# Find printers on WSD ports
Get-Printer | Where-Object { $_.PortName -match '^WSD' } | Select-Object Name, PortName, DriverName

# For each WSD printer, find the IP and create a TCP/IP port
# Step 1: Get the printer's IP (may be in WSD port details or DNS)
$wsdPrinters = Get-Printer | Where-Object { $_.PortName -match '^WSD' }

foreach ($printer in $wsdPrinters) {
    Write-Host "Processing: $($printer.Name)" -ForegroundColor Cyan
    
    # You'll need the printer's IP - get from WSD discovery or DHCP
    $printerIP = Read-Host "Enter IP for $($printer.Name)"
    $tcpPortName = "IP_$printerIP"
    
    # Create TCP/IP port if it doesn't exist
    if (-not (Get-PrinterPort -Name $tcpPortName -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $tcpPortName -PrinterHostAddress $printerIP
        Write-Host "Created port: $tcpPortName" -ForegroundColor Green
    }
    
    # Update printer to use TCP/IP port
    Set-Printer -Name $printer.Name -PortName $tcpPortName
    Write-Host "Updated $($printer.Name) to use $tcpPortName" -ForegroundColor Green
}
```

**Validate:** `Get-Printer -Name "<name>" | Select-Object PortName` — should show `IP_x.x.x.x`  
**Rollback:** Revert port with `Set-Printer -Name "<name>" -PortName "<old WSD port name>"`

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect all print spooler evidence for escalation
.NOTES     Run on the affected machine. Output saved to C:\Temp\PrintEvidence_<date>.txt
#>

$outputPath = "C:\Temp\PrintEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"
$sb = [System.Text.StringBuilder]::new()

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $null = $sb.AppendLine("`n=== $Title ===")
    try { $result = & $Body; $null = $sb.AppendLine(($result | Out-String)) }
    catch { $null = $sb.AppendLine("ERROR: $_") }
}

Add-Section "System Info" { "$env:COMPUTERNAME | $(Get-Date) | $env:USERNAME" }
Add-Section "Spooler Service State" { Get-Service Spooler, RpcSs, DcomLaunch | Select-Object Name, Status, StartType }
Add-Section "Printer List" { Get-Printer | Select-Object Name, DriverName, PortName, PrinterStatus, Shared }
Add-Section "Printer Drivers" { Get-PrinterDriver | Select-Object Name, PrinterEnvironment, DriverVersion, InfPath }
Add-Section "Printer Ports" { Get-PrinterPort | Select-Object Name, PrinterHostAddress, Protocol, PortNumber }
Add-Section "Active Print Jobs" { Get-PrintJob -PrinterName * -ErrorAction SilentlyContinue | Select-Object PrinterName, Document, JobStatus, UserName, TotalPages }
Add-Section "Spool Folder Contents" { Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS" -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime }
Add-Section "Spool Folder Permissions" { icacls "$env:SystemRoot\System32\spool\PRINTERS" 2>&1 }
Add-Section "Application Errors (Print)" {
    Get-WinEvent -LogName Application -MaxEvents 500 |
        Where-Object { $_.Level -in (1,2) -and $_.Message -match 'spool|print' } |
        Select-Object TimeCreated, Id, ProviderName, Message -First 20
}
Add-Section "System Service Errors (Print)" {
    Get-WinEvent -LogName System -MaxEvents 200 |
        Where-Object { $_.Id -in (7031,7034,7036) -and $_.Message -match 'Print' } |
        Select-Object TimeCreated, Id, Message -First 20
}
Add-Section "Point and Print Policy" {
    $key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
    if (Test-Path $key) { Get-ItemProperty $key } else { "Not configured" }
}
Add-Section "Disk Free Space" {
    $drive = (Split-Path $env:SystemRoot -Qualifier).TrimEnd(':')
    Get-PSDrive $drive | Select-Object Name, Used, Free
}

$output = $sb.ToString()
New-Item -Path (Split-Path $outputPath) -ItemType Directory -Force | Out-Null
$output | Out-File $outputPath -Encoding UTF8
Write-Host "Evidence saved to: $outputPath" -ForegroundColor Green
Write-Host "Upload this file to your ticket." -ForegroundColor Cyan
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check spooler status | `Get-Service Spooler` |
| Restart spooler | `Restart-Service Spooler -Force` |
| List all printers | `Get-Printer \| Select-Object Name, DriverName, PortName, PrinterStatus` |
| List print jobs | `Get-PrintJob -PrinterName *` |
| Clear queue (stop spooler first) | `Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force` |
| List all printer drivers | `Get-PrinterDriver \| Select-Object Name, DriverVersion, InfPath` |
| Remove a printer | `Remove-Printer -Name "<PrinterName>"` |
| Remove a driver | `Remove-PrinterDriver -Name "<DriverName>"` |
| Add TCP/IP port | `Add-PrinterPort -Name "IP_x.x.x.x" -PrinterHostAddress "x.x.x.x"` |
| Change printer port | `Set-Printer -Name "<name>" -PortName "IP_x.x.x.x"` |
| Print spooler event errors | `Get-WinEvent -LogName System \| Where-Object { $_.Id -in (7031,7034) -and $_.Message -match 'Print' }` |
| Fix spool folder permissions | `icacls "$env:SystemRoot\System32\spool\PRINTERS" /grant "SYSTEM:(OI)(CI)F"` |
| Check Point and Print policy | `Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"` |
| Enable driver isolation (registry) | `Set-ItemProperty "HKLM:\...\<DriverName>" -Name PrintDriverIsolationAllowed -Value 1` |
| List driver store entries | `pnputil /enum-drivers` |
| Remove driver from store | `pnputil /delete-driver <oem#.inf> /uninstall` |

---
## 🎓 Learning Pointers

- **PrintNightmare (CVE-2021-34527) permanently changed print management.** The vulnerability allowed SYSTEM-level code execution via print driver installation. Microsoft's fix restricts driver installs to admins and blocks unsigned drivers via Point and Print. Every MSP should have a clear policy on which print servers are approved sources, enforced via GPO `PackagePointAndPrint_TrustedServers`. See: [MS Security Response — CVE-2021-34527](https://msrc.microsoft.com/update-guide/vulnerability/CVE-2021-34527)

- **Type 3 vs Type 4 drivers.** Type 3 (v3) drivers can run in kernel mode — a crash takes down all printing. Type 4 (v4) drivers are always user-mode and always isolated. When replacing printer drivers, prefer v4 if the printer vendor offers it. Universal Print uses v4 exclusively. See: [Printer Driver Design Guide — Driver Types](https://learn.microsoft.com/en-us/windows-hardware/drivers/print/printer-driver-overview)

- **Driver isolation does not apply to v4 drivers** (they're already isolated). It's only relevant for legacy v3 drivers. Enabling it on v3 causes a small performance overhead but is always worth it on servers where printing reliability matters more than render speed. See: [Printer Driver Isolation](https://learn.microsoft.com/en-us/windows-hardware/drivers/print/printer-driver-isolation)

- **Universal Print is the strategic exit from print spooler management.** For M365 E3+ environments, Universal Print moves queue management to Microsoft's cloud. No spooler service, no driver conflicts, no PrintNightmare exposure. The on-premises connector syncs existing printers. Evaluate for any client with more than 5 recurring print issues per month. See: [Universal Print overview](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-whatis)

- **WER (Windows Error Reporting) dumps are the gold standard for driver crash analysis.** After a spooler crash, check `C:\ProgramData\Microsoft\Windows\WER\ReportArchive` for a `Critical_spoolsv` folder. The `.wer` file contains the faulting module and stack — essential for escalating to a printer vendor.

- **The spool folder location can be moved.** If the OS volume is tight, move the spool folder to a data volume: `Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers" -Name DefaultSpoolDirectory -Value "D:\PrintSpool"`, then restart the spooler. Permissions on the new folder must match the default PRINTERS folder ACLs.
