<#
.SYNOPSIS
    Audits MSIX App Attach health on an AVD session host — mount state, AppX registration,
    supporting services/drivers, and (optionally) storage RBAC/connectivity for the package share.

.DESCRIPTION
    Run on an AVD session host (local mode) to diagnose why an App Attach application is missing,
    slow to launch, or crashing. Covers all four phases of the App Attach lifecycle described in
    AppAttach-A.md: Stage (VHD/CimFS mount) -> Register (AppX) -> Use -> Deregister/Destage.

    Local checks (always run):
      - AppXSVC and RDAgentBootLoader service state
      - CimFS driver presence (OS build >= 19041 required)
      - Currently mounted disk images (Get-DiskImage)
      - AppX packages in Staged/Installed state (Get-AppxPackage -AllUsers)
      - Recent AppXDeploymentServer operational log errors/warnings

    Optional checks (when parameters supplied):
      - -PackageSharePath: tests SMB reachability (Test-Path) and TCP 445 connectivity to the
        storage endpoint that hosts the .vhd/.vhdx/.cim package images
      - -AppPartialName: filters AppX package and event log results to a specific application,
        matching the Common Fix Paths flow in AppAttach-B.md

    Flags raised (see Symptom -> Cause Map in AppAttach-A.md):
      NOT_MOUNTED           - No disk image mounted for a package that should be staged
      APPXSVC_STOPPED       - AppX Deployment Service is not running (blocks all registration)
      CIMFS_DRIVER_MISSING  - CimFS driver absent (OS build too old, or driver not installed)
      SHARE_UNREACHABLE     - PackageSharePath supplied but Test-Path / TCP 445 fails
      STAGING_ERRORS_FOUND  - AppXDeploymentServer log has Error-level events in the lookback window
      PACKAGE_NOT_REGISTERED - AppPartialName supplied but no matching AppX package found for any user

    Does NOT attempt any remediation. Read-only diagnostic tool — safe to run against production
    session hosts at any time.

.PARAMETER PackageSharePath
    UNC path to the Azure Files (or other SMB) share hosting MSIX package images, e.g.
    \\storacct.file.core.windows.net\msix-packages. If supplied, tests SMB reachability and
    TCP 445 connectivity to the storage endpoint.

.PARAMETER AppPartialName
    Partial name of a specific application to filter AppX package and event log results on
    (matches AppAttach-B.md's <AppPartialName> placeholder). If omitted, reports on all packages.

.PARAMETER LookbackHours
    How many hours of AppXDeploymentServer operational log to scan for errors/warnings. Default 4.

.PARAMETER ExportPath
    Path to export the JSON evidence report. Defaults to
    C:\Temp\AppAttachHealth_<timestamp>.json.

.EXAMPLE
    .\Get-AVDAppAttachHealth.ps1

    Runs all local checks with no package share or app filter.

.EXAMPLE
    .\Get-AVDAppAttachHealth.ps1 -PackageSharePath '\\stcontosoavd.file.core.windows.net\msix' -AppPartialName 'Acrobat'

    Also tests the package share and filters AppX/event results to packages matching "Acrobat".

.NOTES
    Requires: Run locally on the AVD session host. No Az module needed for local-only checks.
    Run as: Administrator recommended (some event log channels and Get-AppxPackage -AllUsers
    require elevation).
    Safe to run: Read-only. No mounts, registrations, or services are modified.
#>

[CmdletBinding()]
param(
    [string]$PackageSharePath,
    [string]$AppPartialName,
    [int]$LookbackHours = 4,
    [string]$ExportPath = "C:\Temp\AppAttachHealth_$(Get-Date -Format 'yyyyMMdd-HHmm').json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Cyan'   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$flags  = [System.Collections.Generic.List[string]]::new()
$report = [ordered]@{
    Timestamp        = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ComputerName     = $env:COMPUTERNAME
    Services         = $null
    CimFSDriver      = $null
    MountedImages    = @()
    AppxPackages     = @()
    StagingEvents    = @()
    ShareCheck       = $null
    Flags            = @()
}

Write-Status "MSIX App Attach Health Check — $env:COMPUTERNAME" 'INFO'
Write-Status '=================================================' 'INFO'

#region — Services
Write-Status 'Checking AppXSVC and AVD agent services...' 'INFO'
$svcNames = 'AppXSVC', 'RDAgentBootLoader', 'ShellHWDetection'
$services = Get-Service -Name $svcNames -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType
$report.Services = $services

$appxSvc = $services | Where-Object Name -eq 'AppXSVC'
if (-not $appxSvc -or $appxSvc.Status -ne 'Running') {
    $flags.Add('APPXSVC_STOPPED')
    Write-Status "AppXSVC is not running (Status: $($appxSvc.Status)) — registration will fail." 'ERROR'
} else {
    Write-Status 'AppXSVC running.' 'OK'
}
$services | Format-Table -AutoSize
#endregion

#region — CimFS driver
Write-Status 'Checking CimFS driver (required for .cim containers)...' 'INFO'
try {
    $cimDriver = Get-WindowsDriver -Online -ErrorAction Stop |
        Where-Object { $_.Driver -like '*cim*' -or $_.OriginalFileName -like '*cimfs*' }
} catch {
    $cimDriver = $null
    Write-Status "Get-WindowsDriver failed (may require elevation): $_" 'WARN'
}
$osBuild = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$report.CimFSDriver = @{ DriverFound = [bool]$cimDriver; OSBuild = $osBuild }

if (-not $cimDriver) {
    if ($osBuild -lt 19041) {
        $flags.Add('CIMFS_DRIVER_MISSING')
        Write-Status "CimFS driver not found and OS build $osBuild < 19041 — CimFS unsupported on this host." 'ERROR'
    } else {
        Write-Status "CimFS driver not detected via Get-WindowsDriver (build $osBuild is new enough — may just need enabling)." 'WARN'
    }
} else {
    Write-Status "CimFS driver present (OS build $osBuild)." 'OK'
}
#endregion

#region — Mounted disk images
Write-Status 'Checking mounted disk images (staged VHD/VHDX/CIM)...' 'INFO'
$mounted = Get-DiskImage | Where-Object { $_.Attached } |
    Select-Object ImagePath, Attached, DevicePath, StorageType
$report.MountedImages = $mounted

if (-not $mounted -or $mounted.Count -eq 0) {
    Write-Status 'No disk images currently mounted. If an app should be staged right now, this indicates NOT_MOUNTED.' 'WARN'
    $flags.Add('NOT_MOUNTED')
} else {
    Write-Status "$($mounted.Count) disk image(s) mounted." 'OK'
    $mounted | Format-Table -AutoSize
}
#endregion

#region — AppX packages (staging/registration state)
Write-Status 'Checking AppX packages (Staged/Installed, all users)...' 'INFO'
try {
    $allPkgs = Get-AppxPackage -AllUsers -ErrorAction Stop
} catch {
    Write-Status "Get-AppxPackage -AllUsers failed (requires elevation): $_" 'WARN'
    $allPkgs = @()
}

$filteredPkgs = if ($AppPartialName) {
    $allPkgs | Where-Object { $_.Name -like "*$AppPartialName*" }
} else {
    $allPkgs | Where-Object { $_.PackageUserInformation -like '*Staged*' -or $_.PackageUserInformation -like '*Installed*' }
}

$report.AppxPackages = $filteredPkgs | Select-Object Name, PackageFullName, Version, PackageUserInformation

if ($AppPartialName -and -not $filteredPkgs) {
    $flags.Add('PACKAGE_NOT_REGISTERED')
    Write-Status "No AppX package matching '*$AppPartialName*' found for any user — staging/registration never ran." 'ERROR'
} elseif ($filteredPkgs) {
    Write-Status "$($filteredPkgs.Count) matching AppX package(s) found." 'OK'
    $filteredPkgs | Select-Object Name, Version, PackageUserInformation | Format-Table -AutoSize -Wrap
} else {
    Write-Status 'No staged/installed App Attach packages found on this host.' 'WARN'
}
#endregion

#region — AppXDeploymentServer event log
Write-Status "Scanning AppXDeploymentServer log for errors/warnings (last $LookbackHours h)..." 'INFO'
$since = (Get-Date).AddHours(-$LookbackHours)
try {
    $events = Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -ErrorAction Stop |
        Where-Object { $_.TimeCreated -ge $since -and $_.LevelDisplayName -in @('Error', 'Warning') }
    if ($AppPartialName) {
        $events = $events | Where-Object { $_.Message -like "*$AppPartialName*" }
    }
} catch {
    Write-Status "Could not read AppXDeploymentServer log: $_" 'WARN'
    $events = @()
}

$report.StagingEvents = $events | Select-Object TimeCreated, Id, LevelDisplayName, Message

if ($events -and $events.Count -gt 0) {
    $flags.Add('STAGING_ERRORS_FOUND')
    Write-Status "$($events.Count) error/warning event(s) found in the lookback window." 'ERROR'
    $events | Select-Object TimeCreated, Id, LevelDisplayName |
        Select-Object -First 15 | Format-Table -AutoSize
} else {
    Write-Status 'No staging errors/warnings in the lookback window.' 'OK'
}
#endregion

#region — Optional: package share connectivity
if ($PackageSharePath) {
    Write-Status "Checking package share reachability: $PackageSharePath" 'INFO'
    $shareOk = Test-Path $PackageSharePath -ErrorAction SilentlyContinue

    $storageHost = ($PackageSharePath -replace '^\\\\([^\\]+)\\.*', '$1')
    $tcpOk = $false
    if ($storageHost) {
        try {
            $tcpOk = (Test-NetConnection -ComputerName $storageHost -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded
        } catch { $tcpOk = $false }
    }

    $report.ShareCheck = @{ Path = $PackageSharePath; PathReachable = $shareOk; StorageHost = $storageHost; Port445 = $tcpOk }

    if (-not $shareOk -or -not $tcpOk) {
        $flags.Add('SHARE_UNREACHABLE')
        Write-Status "Share check FAILED — PathReachable=$shareOk, Port445=$tcpOk. Check NSG/firewall, Private Endpoint DNS, and Storage File Data SMB Share Reader RBAC on the computer account." 'ERROR'
    } else {
        Write-Status 'Package share reachable over SMB (445).' 'OK'
    }
}
#endregion

#region — Summary and export
$report.Flags = $flags

Write-Status '' 'INFO'
Write-Status '=== SUMMARY ===' 'INFO'
if ($flags.Count -eq 0) {
    Write-Status 'No issues flagged. App Attach stack looks healthy on this host.' 'OK'
} else {
    Write-Status "Flags raised: $($flags -join ', ')" 'ERROR'
}

$outDir = Split-Path $ExportPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $ExportPath -Encoding UTF8
Write-Status "Report exported: $ExportPath" 'OK'
#endregion
