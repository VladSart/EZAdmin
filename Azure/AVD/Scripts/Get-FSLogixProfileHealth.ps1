<#
.SYNOPSIS
    Audits FSLogix profile container health on an AVD/RDS session host — services, registry
    config, SMB/Kerberos auth to the profile share, and locked VHD(X) detection.

.DESCRIPTION
    Run on the session host to diagnose the failure modes covered in FSLogix-A.md / FSLogix-B.md:
    temp profile assignment, slow logon, locked VHDX ("profile in use"), and VHD corruption signals.

    Local checks (always run):
      - frxsvc / frxccds service state and CimFS-equivalent frxdrv.sys filter driver presence
      - HKLM:\SOFTWARE\FSLogix\Profiles registry configuration (Enabled, VHDLocations, SizeInMBs,
        ProfileType)
      - SMB (TCP 445) connectivity to the storage host parsed from VHDLocations
      - Kerberos ticket presence for the storage account (klist) — flags NTLM fallback risk
      - Recent Microsoft-FSLogix-Apps/Operational event log entries (Event ID 7 = success,
        43 = failure, 27 = VHD locked)

    Optional checks (when -ProfileSharePath and/or -UserName supplied):
      - Lists the target user's VHD(X) file(s), size, and last-write time
      - Scans for orphaned .lock files under the user's profile folder

    Flags raised (see Symptom -> Cause Map in FSLogix-A.md and Event ID map in FSLogix-B.md):
      SERVICE_NOT_RUNNING     - frxsvc/frxccds stopped — FSLogix will not attach any profile
      DRIVER_MISSING          - frxdrv.sys filter driver not found in fltMC output
      NOT_ENABLED             - Enabled=0 or VHDLocations empty in registry (GPO/Intune not applied)
      SHARE_UNREACHABLE       - TCP 445 to the storage host fails
      NTLM_FALLBACK_RISK      - No CIFS/<storageaccount> Kerberos ticket found in klist output
      RECENT_ATTACH_FAILURE   - Event ID 43 present in the lookback window
      VHD_LOCKED              - Event ID 27 present, or a .lock file found for the target user
      VHD_NOT_FOUND           - ProfileSharePath + UserName supplied but no VHD(X) file located

    Does NOT remove lock files, restart services, or modify any configuration — read-only.

.PARAMETER ProfileSharePath
    UNC path to the FSLogix profile share, e.g. \\storacct.file.core.windows.net\profiles.
    If omitted, the script reads VHDLocations from the registry instead.

.PARAMETER UserName
    SamAccountName (or profile folder prefix) to check for a specific user's VHD(X) and lock files.

.PARAMETER LookbackHours
    Hours of Microsoft-FSLogix-Apps/Operational log to scan. Default 8.

.PARAMETER ExportPath
    Path to export the JSON evidence report. Defaults to C:\Temp\FSLogixHealth_<timestamp>.json.

.EXAMPLE
    .\Get-FSLogixProfileHealth.ps1

    Runs all local checks using the registry's configured VHDLocations.

.EXAMPLE
    .\Get-FSLogixProfileHealth.ps1 -ProfileSharePath '\\stcontosoavd.file.core.windows.net\profiles' -UserName 'jsmith'

    Also looks up jsmith's VHD file and checks for lock files.

.NOTES
    Requires: Run locally on the session host. FSLogix Apps must be installed for most checks
    to return meaningful data.
    Run as: Administrator recommended (service status and some event log channels need elevation).
    Safe to run: Read-only. No services restarted, no lock files removed, no VHDs modified.
#>

[CmdletBinding()]
param(
    [string]$ProfileSharePath,
    [string]$UserName,
    [int]$LookbackHours = 8,
    [string]$ExportPath = "C:\Temp\FSLogixHealth_$(Get-Date -Format 'yyyyMMdd-HHmm').json"
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
    Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ComputerName   = $env:COMPUTERNAME
    Services       = $null
    Driver         = $null
    Registry       = $null
    ShareCheck     = $null
    KerberosCheck  = $null
    RecentEvents   = @()
    UserVHDCheck   = $null
    Flags          = @()
}

Write-Status "FSLogix Profile Health Check — $env:COMPUTERNAME" 'INFO'
Write-Status '=================================================' 'INFO'

#region — Services
Write-Status 'Checking FSLogix services...' 'INFO'
$services = Get-Service -Name 'frxsvc', 'frxccds' -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType
$report.Services = $services

$stopped = $services | Where-Object { $_.Status -ne 'Running' }
if (-not $services -or $services.Count -eq 0) {
    $flags.Add('SERVICE_NOT_RUNNING')
    Write-Status 'FSLogix services not found — FSLogix may not be installed.' 'ERROR'
} elseif ($stopped) {
    $flags.Add('SERVICE_NOT_RUNNING')
    Write-Status "Service(s) not running: $($stopped.Name -join ', ')" 'ERROR'
} else {
    Write-Status 'frxsvc / frxccds running.' 'OK'
}
$services | Format-Table -AutoSize
#endregion

#region — Filter driver
Write-Status 'Checking frxdrv.sys filter driver registration...' 'INFO'
try {
    $fltOutput = & fltMC 2>&1 | Out-String
} catch {
    $fltOutput = ''
    Write-Status "fltMC failed to run: $_" 'WARN'
}
$driverPresent = $fltOutput -match 'frx'
$report.Driver = @{ Present = $driverPresent; RawOutput = ($fltOutput -split "`n" | Select-Object -First 20) -join ' | ' }

if (-not $driverPresent) {
    $flags.Add('DRIVER_MISSING')
    Write-Status 'frxdrv/frxccd filter driver not found in fltMC output.' 'ERROR'
} else {
    Write-Status 'FSLogix filter driver present.' 'OK'
}
#endregion

#region — Registry configuration
Write-Status 'Checking FSLogix registry configuration...' 'INFO'
try {
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Profiles' -ErrorAction Stop
} catch {
    $reg = $null
}

$report.Registry = if ($reg) {
    @{
        Enabled       = $reg.Enabled
        VHDLocations  = $reg.VHDLocations
        SizeInMBs     = $reg.SizeInMBs
        ProfileType   = if ($reg.PSObject.Properties.Name -contains 'ProfileType') { $reg.ProfileType } else { $null }
    }
} else { $null }

if (-not $reg -or $reg.Enabled -ne 1 -or [string]::IsNullOrWhiteSpace($reg.VHDLocations)) {
    $flags.Add('NOT_ENABLED')
    Write-Status 'FSLogix not enabled or VHDLocations empty — GPO/Intune policy not applying.' 'ERROR'
} else {
    Write-Status "Enabled=$($reg.Enabled), VHDLocations=$($reg.VHDLocations), SizeInMBs=$($reg.SizeInMBs)" 'OK'
}
#endregion

#region — Share reachability
$sharePath = if ($ProfileSharePath) { $ProfileSharePath } elseif ($reg) { $reg.VHDLocations } else { $null }

if ($sharePath) {
    Write-Status "Checking share connectivity: $sharePath" 'INFO'
    $storageHost = ($sharePath -replace '^\\\\([^\\]+)\\.*', '$1')
    $tcpOk = $false
    try {
        $tcpOk = (Test-NetConnection -ComputerName $storageHost -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded
    } catch { $tcpOk = $false }

    $report.ShareCheck = @{ Path = $sharePath; StorageHost = $storageHost; Port445 = $tcpOk }

    if (-not $tcpOk) {
        $flags.Add('SHARE_UNREACHABLE')
        Write-Status "TCP 445 to $storageHost FAILED — check NSG/firewall and Private Endpoint DNS." 'ERROR'
    } else {
        Write-Status "TCP 445 to $storageHost OK." 'OK'
    }

    #region — Kerberos ticket check
    Write-Status 'Checking Kerberos tickets (klist) for storage account CIFS SPN...' 'INFO'
    try {
        $klistOutput = & klist 2>&1 | Out-String
    } catch {
        $klistOutput = ''
    }
    $hasCifsTicket = $klistOutput -match "cifs/$storageHost" -or $klistOutput -match 'cifs/'
    $report.KerberosCheck = @{ HasCifsTicket = $hasCifsTicket }

    if (-not $hasCifsTicket) {
        $flags.Add('NTLM_FALLBACK_RISK')
        Write-Status 'No CIFS Kerberos ticket found — session may be falling back to NTLM (slower logon, and blocked entirely if NTLM is disabled).' 'WARN'
    } else {
        Write-Status 'CIFS Kerberos ticket present.' 'OK'
    }
    #endregion
} else {
    Write-Status 'No share path available (registry empty and -ProfileSharePath not supplied) — skipping share/Kerberos checks.' 'WARN'
}
#endregion

#region — Recent FSLogix events
Write-Status "Scanning Microsoft-FSLogix-Apps/Operational log (last $LookbackHours h)..." 'INFO'
$since = (Get-Date).AddHours(-$LookbackHours)
try {
    $events = Get-WinEvent -LogName 'Microsoft-FSLogix-Apps/Operational' -ErrorAction Stop |
        Where-Object { $_.TimeCreated -ge $since }
    if ($UserName) {
        $events = $events | Where-Object { $_.Message -like "*$UserName*" }
    }
} catch {
    Write-Status "Could not read FSLogix event log: $_" 'WARN'
    $events = @()
}

$report.RecentEvents = $events | Select-Object TimeCreated, Id, LevelDisplayName, Message | Select-Object -First 100

$failures = $events | Where-Object Id -eq 43
$locked   = $events | Where-Object Id -eq 27
$success  = $events | Where-Object Id -eq 7

if ($failures) {
    $flags.Add('RECENT_ATTACH_FAILURE')
    Write-Status "$($failures.Count) attach failure event(s) (ID 43) found." 'ERROR'
}
if ($locked) {
    $flags.Add('VHD_LOCKED')
    Write-Status "$($locked.Count) VHD-locked event(s) (ID 27) found." 'ERROR'
}
if ($success -and -not $failures -and -not $locked) {
    Write-Status "$($success.Count) successful attach event(s) (ID 7) found, no failures in window." 'OK'
}
if (-not $events -or $events.Count -eq 0) {
    Write-Status 'No FSLogix events in the lookback window (or user filter matched nothing).' 'WARN'
}
#endregion

#region — Optional user VHD / lock file check
if ($sharePath -and $UserName) {
    Write-Status "Looking up VHD(X) for user '$UserName' on $sharePath..." 'INFO'
    try {
        $userVhds = Get-ChildItem "$sharePath\$UserName*" -Recurse -Filter '*.vhd*' -ErrorAction SilentlyContinue
        $lockFiles = Get-ChildItem "$sharePath\$UserName*" -Recurse -Filter '*.lock' -ErrorAction SilentlyContinue
    } catch {
        $userVhds = @(); $lockFiles = @()
        Write-Status "Could not enumerate user folder: $_" 'WARN'
    }

    $report.UserVHDCheck = @{
        VHDsFound  = $userVhds | Select-Object FullName, @{N='SizeMB';E={[math]::Round($_.Length/1MB,1)}}, LastWriteTime
        LockFiles  = $lockFiles | Select-Object FullName, LastWriteTime
    }

    if (-not $userVhds -or $userVhds.Count -eq 0) {
        $flags.Add('VHD_NOT_FOUND')
        Write-Status "No VHD(X) file found for '$UserName' — user has never logged on, or folder naming differs from SamAccountName." 'ERROR'
    } else {
        Write-Status "$($userVhds.Count) VHD(X) file(s) found for '$UserName'." 'OK'
        $userVhds | Select-Object FullName, @{N='SizeMB';E={[math]::Round($_.Length/1MB,1)}}, LastWriteTime | Format-Table -AutoSize
    }

    if ($lockFiles -and $lockFiles.Count -gt 0) {
        if ('VHD_LOCKED' -notin $flags) { $flags.Add('VHD_LOCKED') }
        Write-Status "$($lockFiles.Count) lock file(s) found — a previous session likely did not clean up. Confirm no active session before clearing." 'ERROR'
    }
}
#endregion

#region — Summary and export
$report.Flags = $flags

Write-Status '' 'INFO'
Write-Status '=== SUMMARY ===' 'INFO'
if ($flags.Count -eq 0) {
    Write-Status 'No issues flagged. FSLogix stack looks healthy on this host.' 'OK'
} else {
    Write-Status "Flags raised: $($flags -join ', ')" 'ERROR'
}

$outDir = Split-Path $ExportPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $ExportPath -Encoding UTF8
Write-Status "Report exported: $ExportPath" 'OK'
#endregion
