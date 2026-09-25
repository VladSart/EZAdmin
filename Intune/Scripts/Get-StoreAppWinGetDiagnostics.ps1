<#
.SYNOPSIS
    Read-only device diagnostic for Intune "Microsoft Store app (new)" (WinGet via IME) install failures.

.DESCRIPTION
    Companion to Intune/Troubleshooting/StoreAppsWinGet-B.md and StoreAppsWinGet-A.md.
    Runs on the affected Windows device and checks every layer that a Store app (new) install
    depends on:
      - Intune Management Extension service state and version
      - Desktop App Installer (WinGet engine) registration, version and winget.exe path
      - Hardware prerequisites (logical processor count >= 2, architecture)
      - Join type (Entra joined / registered / domain joined), which decides the valid install context
      - Store and App Installer policies from both MDM (PolicyManager) and GPO (Policies) sources,
        each flagged as blocking or harmless for Intune installs
      - WinHTTP proxy and TCP 443 reachability to the Store and WinGet endpoints
      - The last WinGet (0x8A15xxxx) and 0x87D1041C errors in the IME AppWorkload logs
      - Optional: per-package presence (AppX per-user vs provisioned) and log hits for a -PackageId

    It does NOT:
      - Install, repair, re-register or remove anything
      - Query Intune/Graph (tenant-side assignment state lives in the portal)
      - Test vendor-hosted content hosts for Win32 Store listings (unknown until the WinGet log names them)

.PARAMETER PackageId
    Optional Store product ID (for example 9WZDNCRFJ3PZ or XP8BT8DW290MPQ) to search for in the IME logs.

.PARAMETER AppNameLike
    Optional AppX name wildcard (for example '*CompanyPortal*') used to report per-user vs provisioned presence.

.PARAMETER LogLines
    How many recent matching IME log lines to report. Default 15.

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP

.EXAMPLE
    .\Get-StoreAppWinGetDiagnostics.ps1

.EXAMPLE
    .\Get-StoreAppWinGetDiagnostics.ps1 -PackageId 9WZDNCRFJ3PZ -AppNameLike '*CompanyPortal*' -OutputPath C:\Temp

.NOTES
    Requires: Windows 10/11, PowerShell 5.1+. Run elevated. Get-AppxPackage -AllUsers and the
    ProgramData IME logs both need admin rights.
    Safe: read-only. Network tests open TCP connections only.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$PackageId,
    [string]$AppNameLike,
    [ValidateRange(1, 200)][int]$LogLines = 15,
    [string]$OutputPath = $env:TEMP
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
    param([string]$Area, [string]$Check, [string]$Value, [string]$Status = "INFO", [string]$Note = "")
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Value = $Value; Status = $Status; Note = $Note })
    Write-Status "$Area | $Check = $Value $(if ($Note) { "($Note)" })" $Status
}

function Get-RegValues {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $h = @{}
    foreach ($p in $item.PSObject.Properties) {
        if ($p.Name -notlike 'PS*') { $h[$p.Name] = $p.Value }
    }
    return $h
}

# ── Preflight ───────────────────────────────────────────────────────
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$os = Get-CimInstance Win32_OperatingSystem
Add-Result "Device" "OS" "$($os.Caption) build $($os.BuildNumber)"
Add-Result "Device" "Architecture" $env:PROCESSOR_ARCHITECTURE $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'WARN' } else { 'OK' }) `
    $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'Store apps with ARM64 installers are not supported by Intune' } else { '' })
$cores = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Add-Result "Device" "LogicalProcessors" "$cores" $(if ($cores -ge 2) { 'OK' } else { 'ERROR' }) 'Store apps require >= 2 cores'

# ── Detect: IME ─────────────────────────────────────────────────────
$ime = Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
if ($null -eq $ime) {
    Add-Result "IME" "Service" "Missing" "ERROR" "No IME = no Store (new) installs. Check enrollment and whether an IME workload is assigned"
} else {
    Add-Result "IME" "Service" "$($ime.Status) / $($ime.StartType)" $(if ($ime.Status -eq 'Running') { 'OK' } else { 'ERROR' })
    $imeExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe'
    if (Test-Path $imeExe) { Add-Result "IME" "Version" ((Get-Item $imeExe).VersionInfo.FileVersion) "OK" }
}

# ── Detect: WinGet engine ───────────────────────────────────────────
$dai = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)
if ($dai.Count -eq 0) {
    Add-Result "Engine" "DesktopAppInstaller" "Not installed" "ERROR" "WinGet engine missing (LTSC / debloated image?) - see Fix 2"
} else {
    $latest = $dai | Sort-Object { [version]$_.Version } | Select-Object -Last 1
    Add-Result "Engine" "DesktopAppInstaller" "$($latest.Version) Status=$($latest.Status)" $(if ("$($latest.Status)" -eq 'Ok') { 'OK' } else { 'WARN' })
}
$wgPath = $null
$wgCandidates = @(Resolve-Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue)
if ($wgCandidates.Count -gt 0) {
    $wgPath = ($wgCandidates | Sort-Object Path | Select-Object -Last 1).Path
    Add-Result "Engine" "winget.exe" $wgPath "OK"
} else {
    Add-Result "Engine" "winget.exe" "Not resolvable for SYSTEM" "WARN"
}

# ── Detect: join type ───────────────────────────────────────────────
$dsreg = (& dsregcmd.exe /status) 2>$null
$aadj = if ($dsreg -match 'AzureAdJoined\s*:\s*YES') { 'YES' } else { 'NO' }
$wpj  = if ($dsreg -match 'WorkplaceJoined\s*:\s*YES') { 'YES' } else { 'NO' }
$dj   = if ($dsreg -match 'DomainJoined\s*:\s*YES') { 'YES' } else { 'NO' }
$joinNote = if ($aadj -eq 'NO' -and $wpj -eq 'YES') { 'Entra registered: use System install behavior only' } else { '' }
Add-Result "Identity" "JoinType" "AzureAdJoined=$aadj WorkplaceJoined=$wpj DomainJoined=$dj" $(if ($joinNote) { 'WARN' } else { 'OK' }) $joinNote

# ── Detect: policies ────────────────────────────────────────────────
# Each entry: registry path, value name, value that blocks Intune (or $null = informational), note
$policyChecks = @(
    @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'; N='EnableAppInstaller'; Bad=0; Note='GPO: disables WinGet engine used by IME' },
    @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'; N='EnableMicrosoftStoreSource'; Bad=0; Note='GPO: removes msstore source (0x8A15001B/1C)' },
    @{ P='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DesktopAppInstaller'; N='EnableAppInstaller'; Bad=$null; Note='MDM ADMX-backed; inspect value data' },
    @{ P='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DesktopAppInstaller'; N='EnableMicrosoftStoreSource'; Bad=$null; Note='MDM ADMX-backed; inspect value data' },
    @{ P='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N='RequirePrivateStoreOnly'; Bad=1; Note='Legacy lockdown; can interfere with msstore - prefer RemoveWindowsStore' },
    @{ P='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement'; N='RequirePrivateStoreOnly'; Bad=1; Note='Legacy lockdown; can interfere with msstore - prefer RemoveWindowsStore' },
    @{ P='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement'; N='DisableStoreOriginatedApps'; Bad=1; Note='Store apps will not launch' },
    @{ P='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationManagement'; N='AllowAppStoreAutoUpdate'; Bad=0; Note='UWP updates blocked (Win32 Store apps still updated by Intune)' },
    @{ P='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N='AutoDownload'; Bad=2; Note='GPO: UWP auto-update turned off' },
    @{ P='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N='RemoveWindowsStore'; Bad=$null; Note='Turn off Store app: does NOT block Intune installs' }
)
foreach ($c in $policyChecks) {
    $vals = Get-RegValues -Path $c.P
    if ($null -eq $vals -or -not $vals.ContainsKey($c.N)) { continue }
    $v = $vals[$c.N]
    $status = 'INFO'
    if ($null -ne $c.Bad) { $status = if ("$v" -eq "$($c.Bad)") { 'ERROR' } else { 'OK' } }
    Add-Result "Policy" "$($c.N) [$(Split-Path $c.P -Leaf)]" "$v" $status $c.Note
}
if (-not ($results | Where-Object Area -eq 'Policy')) { Add-Result "Policy" "Store/AppInstaller policies" "None set" "OK" }

# ── Detect: network ─────────────────────────────────────────────────
$proxy = (& netsh.exe winhttp show proxy) -join ' '
$proxyVal = if ($proxy -match 'Direct access') { 'Direct access (no WinHTTP proxy)' } else { ($proxy -replace '\s+', ' ').Trim() }
Add-Result "Network" "WinHTTP proxy (SYSTEM)" $proxyVal
foreach ($h in 'storeedgefd.dsx.mp.microsoft.com', 'displaycatalog.mp.microsoft.com', 'cdn.winget.microsoft.com') {
    $ok = $false
    try { $ok = [bool](Test-NetConnection -ComputerName $h -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet) } catch { $ok = $false }
    Add-Result "Network" "TCP443 $h" "$ok" $(if ($ok) { 'OK' } else { 'ERROR' })
}

# ── Detect: IME logs ────────────────────────────────────────────────
$logDir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
$appLogs = @(Get-ChildItem -Path $logDir -Filter 'AppWorkload*.log' -ErrorAction SilentlyContinue)
if ($appLogs.Count -eq 0) {
    Add-Result "Logs" "AppWorkload.log" "Not found" "WARN" "IME has not processed any app workload yet"
} else {
    $errHits = @(Select-String -Path $appLogs.FullName -Pattern '0x8A15[0-9A-Fa-f]{4}|0x87D1041C' -ErrorAction SilentlyContinue)
    Add-Result "Logs" "WinGet/detection error lines" "$($errHits.Count)" $(if ($errHits.Count -gt 0) { 'WARN' } else { 'OK' })
    foreach ($hit in ($errHits | Select-Object -Last $LogLines)) {
        $code = ([regex]::Match($hit.Line, '0x8A15[0-9A-Fa-f]{4}|0x87D1041C')).Value
        $line = $hit.Line; if ($line.Length -gt 300) { $line = $line.Substring(0, 300) }
        Add-Result "Logs" "Error $code" $line "WARN" (Split-Path $hit.Path -Leaf)
    }
    if ($PackageId) {
        $pkgHits = @(Select-String -Path $appLogs.FullName -SimpleMatch -Pattern $PackageId -ErrorAction SilentlyContinue)
        Add-Result "Logs" "Lines mentioning $PackageId" "$($pkgHits.Count)" $(if ($pkgHits.Count -gt 0) { 'OK' } else { 'WARN' }) `
            $(if ($pkgHits.Count -eq 0) { 'Assignment not seen by IME - sync device / restart IME' } else { '' })
        foreach ($hit in ($pkgHits | Select-Object -Last ([math]::Min($LogLines, 5)))) {
            $line = $hit.Line; if ($line.Length -gt 300) { $line = $line.Substring(0, 300) }
            Add-Result "Logs" "Package line" $line "INFO"
        }
    }
}

# ── Detect: package context ─────────────────────────────────────────
if ($AppNameLike) {
    $pkgs = @(Get-AppxPackage -AllUsers -Name $AppNameLike -ErrorAction SilentlyContinue)
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $AppNameLike })
    Add-Result "Package" "Per-user installs ($AppNameLike)" "$($pkgs.Count)"
    foreach ($p in $pkgs) {
        $users = @($p.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Username):$($_.InstallState)" }) -join '; '
        Add-Result "Package" $p.PackageFullName $users
    }
    Add-Result "Package" "Provisioned (System context)" "$($prov.Count)"
    if ($pkgs.Count -gt 0 -and $prov.Count -gt 0) {
        Add-Result "Package" "Context" "Mixed per-user + provisioned" "WARN" "Common cause of 0x87D1041C - standardise on one context"
    }
}

# ── Report ──────────────────────────────────────────────────────────
$csv = Join-Path $OutputPath ("StoreAppWinGetDiagnostics_{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$errs = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. $errs error(s), $warns warning(s). Report: $csv" $(if ($errs) { 'ERROR' } elseif ($warns) { 'WARN' } else { 'OK' })
