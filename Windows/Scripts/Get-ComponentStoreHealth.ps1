<#
.SYNOPSIS
    Read-only health check of the Windows component store (WinSxS / CBS) and servicing prerequisites.

.DESCRIPTION
    Collects the evidence needed to decide whether a failing update / SFC / DISM problem is
    component store corruption, a missing repair source, a stuck servicing transaction, or
    something else (space, filter drivers, disabled TrustedInstaller).

    Checks:
      - OS build + UBR + edition (what a repair source must match)
      - Pending servicing transaction (RebootPending / SessionsPending / PackagesPending / pending.xml)
      - TrustedInstaller service start type
      - DISM /CheckHealth (always) and /ScanHealth (optional, slow)
      - DISM /AnalyzeComponentStore (actual size, cleanup recommended)
      - StartComponentCleanup scheduled task state
      - Repair-source policy (RepairContentServerSource / LocalSourcePath) vs WSUS management
      - Free space on C: and the EFI System Partition
      - Recent CBS.log corruption markers
      - Packages not in Installed/Superseded state
      - Third-party filesystem minifilters (fltmc)
      - Recent Setup event log failures

    Does NOT repair anything. It never runs /RestoreHealth, SFC, cleanup or revert operations.

.PARAMETER OutputPath
    Folder for the CSV report and (optionally) the log bundle. Created if missing.

.PARAMETER RunScanHealth
    Also run DISM /ScanHealth. Takes 5-30 minutes; read-only but CPU/disk heavy.

.PARAMETER CollectLogs
    Copy CBS.log, dism.log and the three newest CbsPersist_*.cab files into OutputPath and zip them.

.EXAMPLE
    .\Get-ComponentStoreHealth.ps1

.EXAMPLE
    .\Get-ComponentStoreHealth.ps1 -OutputPath C:\Temp\CBS-Evidence -RunScanHealth -CollectLogs

.NOTES
    Requires: Windows PowerShell 5.1+, elevated session (DISM /Online needs admin).
    Safe: read-only. ScanHealth sets the CBS corruption flag if it finds corruption (by design).
    Companion to Windows/Troubleshooting/ComponentStore-A.md / ComponentStore-B.md.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\ComponentStoreHealth",
    [switch]$RunScanHealth,
    [switch]$CollectLogs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Check, [string]$Value, [string]$Status, [string]$Note = "")
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; Check = $Check; Value = $Value; Status = $Status; Note = $Note
    })
    Write-Status -Message ("{0}: {1} {2}" -f $Check, $Value, $Note) -Status $Status
}

function Invoke-Dism {
    param([string[]]$Arguments)
    $out = & dism.exe @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# ---------------- Preflight ----------------
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
Write-Status "Component store health check on $env:COMPUTERNAME"

# ---------------- Build ----------------
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$ubr = if ($cv.PSObject.Properties['UBR']) { $cv.UBR } else { 'n/a' }
$build = "{0} {1} {2}.{3}" -f $cv.ProductName, $cv.EditionID, $cv.CurrentBuildNumber, $ubr
Add-Result -Check "OS build" -Value $build -Status "INFO" -Note "(repair source must match build/edition/language)"

# ---------------- Pending transaction ----------------
$cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
$pending = @()
foreach ($k in 'RebootPending', 'SessionsPending', 'PackagesPending') {
    if (Test-Path (Join-Path $cbsKey $k)) { $pending += $k }
}
if (Test-Path "$env:WINDIR\WinSxS\pending.xml") { $pending += 'pending.xml' }
if ($pending.Count -gt 0) {
    Add-Result -Check "Pending servicing" -Value ($pending -join ',') -Status "WARN" -Note "Reboot before any repair; persists after 2 reboots -> RevertPendingActions"
} else {
    Add-Result -Check "Pending servicing" -Value "None" -Status "OK"
}

# ---------------- TrustedInstaller ----------------
try {
    $ti = Get-CimInstance -ClassName Win32_Service -Filter "Name='TrustedInstaller'"
    $st = if ($ti.StartMode -eq 'Disabled') { 'ERROR' } else { 'OK' }
    Add-Result -Check "TrustedInstaller" -Value ("{0}/{1}" -f $ti.StartMode, $ti.State) -Status $st -Note $(if ($st -eq 'ERROR') { 'Must be Manual for servicing' } else { '' })
} catch {
    Add-Result -Check "TrustedInstaller" -Value "Query failed" -Status "WARN" -Note $_.Exception.Message
}

# ---------------- CheckHealth ----------------
$ch = Invoke-Dism -Arguments @('/Online', '/Cleanup-Image', '/CheckHealth')
$ch.Output | Out-File (Join-Path $OutputPath "checkhealth-$stamp.txt")
if ($ch.Output -match 'No component store corruption detected') {
    Add-Result -Check "DISM CheckHealth" -Value "No corruption flagged" -Status "OK" -Note "(flag only - run -RunScanHealth to prove)"
} elseif ($ch.Output -match 'not repairable') {
    Add-Result -Check "DISM CheckHealth" -Value "Not repairable" -Status "ERROR"
} elseif ($ch.Output -match 'repairable') {
    Add-Result -Check "DISM CheckHealth" -Value "Repairable corruption flagged" -Status "WARN"
} else {
    Add-Result -Check "DISM CheckHealth" -Value ("Exit {0}" -f $ch.ExitCode) -Status "WARN" -Note "Unrecognised output - see checkhealth txt"
}

# ---------------- ScanHealth (optional) ----------------
if ($RunScanHealth) {
    Write-Status "Running DISM /ScanHealth (5-30 min)..."
    $sh = Invoke-Dism -Arguments @('/Online', '/Cleanup-Image', '/ScanHealth')
    $sh.Output | Out-File (Join-Path $OutputPath "scanhealth-$stamp.txt")
    if ($sh.Output -match 'No component store corruption detected') {
        Add-Result -Check "DISM ScanHealth" -Value "Clean" -Status "OK"
    } elseif ($sh.Output -match 'not repairable') {
        Add-Result -Check "DISM ScanHealth" -Value "Not repairable" -Status "ERROR" -Note "Playbook 4 (in-place upgrade)"
    } elseif ($sh.Output -match 'repairable') {
        Add-Result -Check "DISM ScanHealth" -Value "Repairable" -Status "WARN" -Note "RestoreHealth with matching source"
    } else {
        Add-Result -Check "DISM ScanHealth" -Value ("Exit {0}" -f $sh.ExitCode) -Status "WARN"
    }
} else {
    Add-Result -Check "DISM ScanHealth" -Value "Skipped" -Status "INFO" -Note "Use -RunScanHealth"
}

# ---------------- AnalyzeComponentStore ----------------
$an = Invoke-Dism -Arguments @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore')
$an.Output | Out-File (Join-Path $OutputPath "analyze-$stamp.txt")
$actual = ([regex]::Match($an.Output, 'Actual Size of Component Store\s*:\s*(.+)')).Groups[1].Value.Trim()
$reclaim = ([regex]::Match($an.Output, 'Number of Reclaimable Packages\s*:\s*(\d+)')).Groups[1].Value
$recommended = ([regex]::Match($an.Output, 'Component Store Cleanup Recommended\s*:\s*(\w+)')).Groups[1].Value
if ($actual) {
    $st = if ($recommended -eq 'Yes') { 'WARN' } else { 'OK' }
    Add-Result -Check "Store size" -Value $actual -Status $st -Note ("Reclaimable packages: {0}; cleanup recommended: {1}" -f $reclaim, $recommended)
} else {
    Add-Result -Check "Store size" -Value "Could not parse" -Status "WARN" -Note ("DISM exit {0}" -f $an.ExitCode)
}

# ---------------- Cleanup task ----------------
try {
    $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Servicing\' -TaskName 'StartComponentCleanup' -ErrorAction Stop
    $st = if ($task.State -eq 'Disabled') { 'WARN' } else { 'OK' }
    Add-Result -Check "StartComponentCleanup task" -Value $task.State -Status $st
} catch {
    Add-Result -Check "StartComponentCleanup task" -Value "Not found" -Status "WARN"
}

# ---------------- Repair source policy ----------------
$svcPol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -ErrorAction SilentlyContinue
$auPol  = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
$useWsus = ($null -ne $auPol) -and ($auPol.PSObject.Properties['UseWUServer']) -and ($auPol.UseWUServer -eq 1)
$rcss = if ($svcPol -and $svcPol.PSObject.Properties['RepairContentServerSource']) { $svcPol.RepairContentServerSource } else { $null }
$lsp  = if ($svcPol -and $svcPol.PSObject.Properties['LocalSourcePath']) { $svcPol.LocalSourcePath } else { $null }
$polText = "WSUS={0}; RepairContentServerSource={1}; LocalSourcePath={2}" -f $useWsus, $(if ($null -ne $rcss) { $rcss } else { 'unset' }), $(if ($lsp) { $lsp } else { 'unset' })
if ($useWsus -and ($rcss -ne 2) -and (-not $lsp)) {
    Add-Result -Check "Repair source" -Value $polText -Status "WARN" -Note "RestoreHealth will likely fail 0x800f081f - use /Source or set component-repair GPO"
} else {
    Add-Result -Check "Repair source" -Value $polText -Status "OK"
}

# ---------------- Free space ----------------
try {
    $c = Get-Volume -DriveLetter C
    $freeGB = [math]::Round($c.SizeRemaining / 1GB, 1)
    $st = if ($freeGB -lt 10) { 'WARN' } else { 'OK' }
    Add-Result -Check "C: free" -Value ("{0} GB" -f $freeGB) -Status $st
} catch { Add-Result -Check "C: free" -Value "Query failed" -Status "WARN" }

try {
    $esp = Get-Partition -ErrorAction Stop | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
    if ($esp) {
        $espVol = $esp | Get-Volume -ErrorAction Stop
        $espFreeMB = [math]::Round($espVol.SizeRemaining / 1MB, 0)
        $st = if ($espFreeMB -lt 15) { 'WARN' } else { 'OK' }
        Add-Result -Check "EFI partition free" -Value ("{0} MB" -f $espFreeMB) -Status $st -Note $(if ($st -eq 'WARN') { 'Low ESP space is a common 0x800f0922 cause' } else { '' })
    } else {
        Add-Result -Check "EFI partition free" -Value "No GPT ESP (BIOS/MBR?)" -Status "INFO"
    }
} catch { Add-Result -Check "EFI partition free" -Value "Query failed" -Status "INFO" -Note $_.Exception.Message }

# ---------------- CBS.log markers ----------------
$cbsLog = "$env:WINDIR\Logs\CBS\CBS.log"
if (Test-Path $cbsLog) {
    $markers = @(Select-String -Path $cbsLog -Pattern 'CSI Payload Corrupt', 'CSI Manifest', 'Repair failed', 'Failed to get the underlying', 'Mark store corruption' -ErrorAction SilentlyContinue)
    if ($markers.Count -gt 0) {
        $markers | Select-Object -Last 50 | ForEach-Object { $_.Line } | Out-File (Join-Path $OutputPath "cbs-markers-$stamp.txt")
        Add-Result -Check "CBS.log corruption markers" -Value $markers.Count -Status "WARN" -Note "Last 50 in cbs-markers txt"
    } else {
        Add-Result -Check "CBS.log corruption markers" -Value 0 -Status "OK"
    }
} else {
    Add-Result -Check "CBS.log corruption markers" -Value "CBS.log missing" -Status "WARN"
}

# ---------------- Package states ----------------
try {
    $odd = @(Get-WindowsPackage -Online -ErrorAction Stop | Where-Object { $_.PackageState -notin 'Installed', 'Superseded', 'PermanentlyInstalled' })
    if ($odd.Count -gt 0) {
        $odd | Select-Object PackageName, PackageState, ReleaseType, InstallTime | Export-Csv (Join-Path $OutputPath "packages-odd-$stamp.csv") -NoTypeInformation
        Add-Result -Check "Packages not Installed" -Value $odd.Count -Status "WARN" -Note "InstallPending/Staged/etc - see packages-odd csv"
    } else {
        Add-Result -Check "Packages not Installed" -Value 0 -Status "OK"
    }
} catch {
    Add-Result -Check "Packages not Installed" -Value "Query failed" -Status "WARN" -Note $_.Exception.Message
}

# ---------------- Filter drivers ----------------
try {
    $flt = & fltmc.exe filters 2>&1 | Out-String
    $flt | Out-File (Join-Path $OutputPath "fltmc-$stamp.txt")
    $inbox = 'bindflt|wcifs|CldFlt|FileCrypt|luafv|npsvctrig|Wof|FileInfo|storqosflt|WdFilter|UnionFS|bfs|applockerfltr|MsSecFlt|Ntfs|mssecflt|DfsDriver|dedup|CimFS|FileBackup|ProcMon|iorate|gameflt|FsDepends|WinSetupMon'
    $third = @($flt -split "`r?`n" | Where-Object { $_ -match '^\S+\s+\d+\s+\d+' } | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -notmatch "^($inbox)$" })
    $st = if ($third.Count -gt 0) { 'INFO' } else { 'OK' }
    Add-Result -Check "Non-inbox minifilters" -Value $(if ($third.Count) { $third -join ',' } else { 'none' }) -Status $st -Note "AV/DLP/backup filters can block TrustedInstaller"
} catch { Add-Result -Check "Non-inbox minifilters" -Value "fltmc failed" -Status "INFO" }

# ---------------- Setup event log ----------------
try {
    $since = (Get-Date).AddDays(-30)
    $fails = @(Get-WinEvent -FilterHashtable @{ LogName = 'Setup'; Level = 2, 3; StartTime = $since } -ErrorAction SilentlyContinue)
    if ($fails.Count -gt 0) {
        $fails | Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv (Join-Path $OutputPath "setup-events-$stamp.csv") -NoTypeInformation
        Add-Result -Check "Setup log errors/warnings (30d)" -Value $fails.Count -Status "WARN"
    } else {
        Add-Result -Check "Setup log errors/warnings (30d)" -Value 0 -Status "OK"
    }
} catch { Add-Result -Check "Setup log errors/warnings (30d)" -Value "Query failed" -Status "INFO" }

# ---------------- Logs bundle ----------------
if ($CollectLogs) {
    $bundle = Join-Path $OutputPath "logs-$stamp"
    New-Item -Path $bundle -ItemType Directory -Force | Out-Null
    Copy-Item -Path $cbsLog, "$env:WINDIR\Logs\DISM\dism.log" -Destination $bundle -ErrorAction SilentlyContinue
    Get-ChildItem "$env:WINDIR\Logs\CBS" -Filter 'CbsPersist_*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3 | Copy-Item -Destination $bundle -ErrorAction SilentlyContinue
    Compress-Archive -Path "$bundle\*" -DestinationPath "$bundle.zip" -Force
    Write-Status "Log bundle: $bundle.zip" "OK"
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath "ComponentStoreHealth-$env:COMPUTERNAME-$stamp.csv"
$results | Export-Csv -Path $csv -NoTypeInformation
$errs  = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status ("Done. {0} error(s), {1} warning(s). Report: {2}" -f $errs, $warns, $csv) $(if ($errs) { 'ERROR' } elseif ($warns) { 'WARN' } else { 'OK' })
