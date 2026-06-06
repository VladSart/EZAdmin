<#
.SYNOPSIS
    Collects comprehensive print environment diagnostics for a Windows machine.

.DESCRIPTION
    Gathers all relevant print spooler, driver, queue, port, and event log data
    from the local machine (or a remote machine via -ComputerName). Output is
    written to a timestamped CSV + summary text file for ticket escalation or
    proactive health checks.

    Covers:
    - Spooler service state and dependencies
    - All installed printers and their status
    - All printer drivers (name, version, mode, InfPath)
    - Active print jobs
    - Printer ports (TCP/IP, WSD, USB)
    - Spool folder contents and permissions
    - Relevant System and Application event log entries
    - Point and Print / PrintNightmare policy values
    - Disk free space on the OS drive (spool folder host)

.PARAMETER ComputerName
    Target machine name. Defaults to localhost. Requires WinRM if remote.

.PARAMETER OutputPath
    Directory to write output files. Defaults to C:\Temp.

.PARAMETER IncludeEventLogs
    If specified, includes the last 50 print-related events from System and Application logs.
    Adds ~5 seconds to run time.

.EXAMPLE
    .\Get-PrinterDiagnostics.ps1
    Runs against localhost, outputs to C:\Temp.

.EXAMPLE
    .\Get-PrinterDiagnostics.ps1 -ComputerName WORKSTATION01 -OutputPath D:\Support
    Runs against a remote machine, saves to D:\Support.

.EXAMPLE
    .\Get-PrinterDiagnostics.ps1 -IncludeEventLogs
    Includes event log analysis in the report.

.NOTES
    Requires:  Local or remote admin rights.
    Run-as:    Not required for local; WinRM + admin needed for remote.
    Safe:      Read-only — makes no changes to any configuration.
    Tested on: Windows 10 21H2, Windows 11 22H2/23H2, Server 2019/2022
#>

[CmdletBinding()]
param(
    [string]$ComputerName  = $env:COMPUTERNAME,
    [string]$OutputPath    = "C:\Temp",
    [switch]$IncludeEventLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

#region --- Helpers ---

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Invoke-PrintCommand {
    param([string]$ComputerName, [scriptblock]$ScriptBlock)
    if ($ComputerName -eq $env:COMPUTERNAME) {
        & $ScriptBlock
    } else {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ErrorAction SilentlyContinue
    }
}

#endregion

#region --- Preflight ---

Write-Status "Starting printer diagnostics on: $ComputerName" "INFO"

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$reportBase  = Join-Path $OutputPath "PrintDiag_${ComputerName}_${timestamp}"
$summaryFile = "$reportBase.txt"
$csvBase     = $reportBase

$report = [System.Collections.ArrayList]::new()

function Add-Section {
    param([string]$Title)
    $line = "`n" + ("=" * 60) + "`n=== $Title ===`n" + ("=" * 60)
    $null = $report.Add($line)
    Write-Status $Title "INFO"
}

function Add-Data {
    param($Data)
    $null = $report.Add(($Data | Out-String))
}

#endregion

#region --- 1. Service State ---

Add-Section "1. Print Spooler Service State"

$services = Invoke-PrintCommand $ComputerName {
    Get-Service -Name Spooler, RpcSs, DcomLaunch, PlugPlay -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType, @{N='PID';E={(Get-Process -Name ($_.Name) -ErrorAction SilentlyContinue).Id}}
}

Add-Data $services
$services | Export-Csv -Path "$csvBase_Services.csv" -NoTypeInformation -Force

$spooler = $services | Where-Object { $_.Name -eq 'Spooler' }
if ($spooler.Status -ne 'Running') {
    Write-Status "SPOOLER IS NOT RUNNING — status: $($spooler.Status)" "WARN"
} else {
    Write-Status "Spooler is Running" "OK"
}

#endregion

#region --- 2. Printer Inventory ---

Add-Section "2. Installed Printers"

$printers = Invoke-PrintCommand $ComputerName {
    Get-Printer | Select-Object Name, DriverName, PortName, PrinterStatus, Shared, ShareName, Published, Type
}

Add-Data $printers
$printers | Export-Csv -Path "$csvBase_Printers.csv" -NoTypeInformation -Force
Write-Status "Total printers: $($printers.Count)" "INFO"

$offline = $printers | Where-Object { $_.PrinterStatus -ne 'Normal' }
if ($offline) {
    Write-Status "$($offline.Count) printer(s) not in Normal state" "WARN"
    $offline | ForEach-Object { Write-Status "  $($_.Name) → $($_.PrinterStatus)" "WARN" }
}

#endregion

#region --- 3. Driver Inventory ---

Add-Section "3. Printer Drivers"

$drivers = Invoke-PrintCommand $ComputerName {
    Get-PrinterDriver | Select-Object Name, PrinterEnvironment, DriverVersion, PrintProcessor, InfPath,
        @{N='InfPathExists';E={ Test-Path $_.InfPath -ErrorAction SilentlyContinue }}
}

Add-Data $drivers
$drivers | Export-Csv -Path "$csvBase_Drivers.csv" -NoTypeInformation -Force

$badDrivers = $drivers | Where-Object { -not $_.InfPathExists -or $_.InfPath -eq '' }
if ($badDrivers) {
    Write-Status "$($badDrivers.Count) driver(s) with missing InfPath (potential crash risk)" "WARN"
}
Write-Status "Total drivers: $($drivers.Count)" "INFO"

#endregion

#region --- 4. Printer Ports ---

Add-Section "4. Printer Ports"

$ports = Invoke-PrintCommand $ComputerName {
    Get-PrinterPort | Select-Object Name, PrinterHostAddress, Protocol, PortNumber, SNMPEnabled
}

Add-Data $ports
$ports | Export-Csv -Path "$csvBase_Ports.csv" -NoTypeInformation -Force

$wsdPorts = $ports | Where-Object { $_.Name -match '^WSD' }
if ($wsdPorts) {
    Write-Status "$($wsdPorts.Count) WSD port(s) detected — may cause 'always offline' symptoms" "WARN"
}

#endregion

#region --- 5. Active Print Queue ---

Add-Section "5. Active Print Jobs"

$allJobs = Invoke-PrintCommand $ComputerName {
    $jobs = @()
    Get-Printer -ErrorAction SilentlyContinue | ForEach-Object {
        $p = $_.Name
        Get-PrintJob -PrinterName $p -ErrorAction SilentlyContinue | ForEach-Object {
            $jobs += [PSCustomObject]@{
                Printer   = $p
                Document  = $_.Document
                JobStatus = $_.JobStatus
                UserName  = $_.UserName
                Pages     = $_.TotalPages
                Submitted = $_.TimeSubmitted
            }
        }
    }
    $jobs
}

if ($allJobs) {
    Add-Data $allJobs
    $allJobs | Export-Csv -Path "$csvBase_PrintJobs.csv" -NoTypeInformation -Force
    $stuckJobs = $allJobs | Where-Object { $_.JobStatus -match 'Error|Retain|Delet' }
    if ($stuckJobs) {
        Write-Status "$($stuckJobs.Count) stuck job(s) detected" "WARN"
    }
    Write-Status "Total active jobs: $($allJobs.Count)" "INFO"
} else {
    Add-Data "(No active print jobs)"
    Write-Status "Print queue is empty" "OK"
}

#endregion

#region --- 6. Spool Folder Health ---

Add-Section "6. Spool Folder"

$spoolData = Invoke-PrintCommand $ComputerName {
    $path = "$env:SystemRoot\System32\spool\PRINTERS"
    $files = Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue |
        Select-Object Name, Length, LastWriteTime, Extension
    $totalMB = ($files | Measure-Object Length -Sum).Sum / 1MB
    $acl = (Get-Acl $path -ErrorAction SilentlyContinue).AccessToString

    # OS drive free space
    $drive = (Split-Path $env:SystemRoot -Qualifier).TrimEnd(':')
    $free  = (Get-PSDrive $drive -ErrorAction SilentlyContinue).Free / 1GB

    [PSCustomObject]@{
        SpoolPath    = $path
        FileCount    = $files.Count
        TotalMB      = [math]::Round($totalMB, 2)
        DriveFreeGB  = [math]::Round($free, 2)
        ACL          = $acl
    }
}

Add-Data $spoolData

if ($spoolData.FileCount -gt 0) {
    Write-Status "Spool folder has $($spoolData.FileCount) file(s) — $($spoolData.TotalMB) MB" "WARN"
} else {
    Write-Status "Spool folder is empty" "OK"
}
if ($spoolData.DriveFreeGB -lt 5) {
    Write-Status "OS drive has only $($spoolData.DriveFreeGB) GB free — spooler may reject jobs!" "WARN"
} else {
    Write-Status "OS drive free space: $($spoolData.DriveFreeGB) GB" "OK"
}

#endregion

#region --- 7. PrintNightmare Policy Values ---

Add-Section "7. Point and Print / PrintNightmare Policy"

$pnpPolicy = Invoke-PrintCommand $ComputerName {
    $keys = @{
        'PointAndPrint'    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
        'PackagePnP'       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PackagePointAndPrint'
    }
    $result = [ordered]@{}
    foreach ($k in $keys.Keys) {
        if (Test-Path $keys[$k]) {
            $result[$k] = Get-ItemProperty $keys[$k]
        } else {
            $result[$k] = "(not configured — Windows defaults apply)"
        }
    }
    $result
}

Add-Data ($pnpPolicy | Out-String)

if ($pnpPolicy['PointAndPrint'] -is [Microsoft.Win32.RegistryKey] -or
    $pnpPolicy['PointAndPrint'] -is [PSCustomObject]) {
    $val = $pnpPolicy['PointAndPrint']
    if ($val.NoWarningNoElevationOnInstall -eq 1) {
        Write-Status "NoWarningNoElevationOnInstall = 1 — PrintNightmare mitigation partially disabled" "WARN"
    }
}

#endregion

#region --- 8. Event Logs (optional) ---

if ($IncludeEventLogs) {
    Add-Section "8. Recent Print-Related Event Log Errors"

    $events = Invoke-PrintCommand $ComputerName {
        $appEvents = Get-WinEvent -LogName Application -MaxEvents 500 -ErrorAction SilentlyContinue |
            Where-Object { $_.Level -in (1,2) -and $_.Message -match 'spool|print' } |
            Select-Object TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message -First 20

        $sysEvents = Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -in (7031,7034,7036) -and $_.Message -match 'Print|Spooler' } |
            Select-Object TimeCreated, LogName, Id, ProviderName, LevelDisplayName, Message -First 20

        @($appEvents) + @($sysEvents) | Sort-Object TimeCreated -Descending
    }

    if ($events) {
        Add-Data $events
        $events | Export-Csv -Path "$csvBase_Events.csv" -NoTypeInformation -Force
        Write-Status "$($events.Count) print-related event(s) found" "WARN"
    } else {
        Add-Data "(No print-related errors in event log)"
        Write-Status "No relevant event log entries" "OK"
    }
}

#endregion

#region --- Summary ---

Add-Section "SUMMARY"

$summary = @(
    "Computer:      $ComputerName"
    "Report Date:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "Spooler:       $($spooler.Status)"
    "Printers:      $($printers.Count) total, $($offline.Count) not-Normal"
    "Drivers:       $($drivers.Count) total, $($badDrivers.Count) missing InfPath"
    "Print Jobs:    $($allJobs.Count) active"
    "Spool Files:   $($spoolData.FileCount) files ($($spoolData.TotalMB) MB)"
    "OS Drive Free: $($spoolData.DriveFreeGB) GB"
    "WSD Ports:     $($wsdPorts.Count)"
    "Output Files:  $reportBase*"
)

$summary | ForEach-Object { $null = $report.Add($_) }
$summary | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }

#endregion

#region --- Write output ---

$report | Out-File -FilePath $summaryFile -Encoding UTF8
Write-Status "Report saved: $summaryFile" "OK"

#endregion
