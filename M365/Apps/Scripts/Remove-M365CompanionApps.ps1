<#
.SYNOPSIS
    Detects (default) or removes (-Remediate) the retiring Microsoft 365 companion apps
    (Calendar, People, Files — AppX package Microsoft.M365Companions) on a Windows device.

.DESCRIPTION
    Microsoft 365 companion apps retire on 16 December 2026 (MC1474111). Microsoft stopped the
    auto-install and security fixes on 18 Sept 2026 but does NOT uninstall existing copies.

    Default (report) mode is read-only and Intune-Remediation compatible:
      exit 0 = clean, exit 1 = package / provisioned package present.

    Checks:
      1. Registered package for any user (Get-AppxPackage -AllUsers)
      2. Provisioned package (Get-AppxProvisionedPackage -Online) — the copy new profiles receive
      3. Leftover per-user data folders (%LOCALAPPDATA%\Packages\Microsoft.M365Companions_8wekyb3d8bbwe)
      4. Running companion processes (removal deferred until sign-out/restart if present)
      5. Context: OS caption/build, Click-to-Run presence (the auto-install population)

    -Remediate removes registrations for all users, the provisioned package, and leftover
    data folders (cache/settings only — no Microsoft 365 data is stored there), then re-validates.

    Does NOT change the Microsoft 365 Apps admin center auto-install toggle or Intune app
    assignments — those are tenant-side (see CompanionAppsRetirement-B.md Fix 1/2). If an Intune
    Required assignment still exists, the app will be reinstalled after this script removes it.

.PARAMETER Remediate
    Perform removal. Without it the script only reports.

.PARAMETER KeepDataFolders
    With -Remediate, skip deleting leftover per-user package data folders.

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:ProgramData\EZAdmin\CompanionApps

.EXAMPLE
    .\Remove-M365CompanionApps.ps1
    Report only. Exit 1 if anything companion-related is present (Remediation detection script).

.EXAMPLE
    .\Remove-M365CompanionApps.ps1 -Remediate
    Remove for all users + provisioned copy + data folders, then validate.

.NOTES
    Requires: Windows 10 1809+ / Windows 11, PowerShell 5.1, elevation or SYSTEM.
    Run as SYSTEM, 64-bit, when deployed via Intune Remediations.
    Report mode: safe. -Remediate: removes an app; no rollback (product retired, reinstall unsupported).
    Reference: https://learn.microsoft.com/en-us/microsoft-365-apps/companions/companion-app-retirement
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Remediate,
    [switch]$KeepDataFolders,
    [string]$OutputPath = (Join-Path $env:ProgramData 'EZAdmin\CompanionApps')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$PackageName   = 'Microsoft.M365Companions'
$FamilySuffix  = '_8wekyb3d8bbwe'
$results       = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Check, [string]$Finding, [string]$Detail)
    $results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('s')
        Computer  = $env:COMPUTERNAME
        Mode      = $(if ($Remediate) { 'Remediate' } else { 'Report' })
        Check     = $Check
        Finding   = $Finding
        Detail    = $Detail
    })
}

function Get-CompanionState {
    $reg  = @(Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue)
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $PackageName })
    $data = @(Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Join-Path $_.FullName ("AppData\Local\Packages\{0}{1}" -f $PackageName, $FamilySuffix)
                if (Test-Path -LiteralPath $p) { $p }
            })
    [pscustomobject]@{ Registered = $reg; Provisioned = $prov; DataFolders = $data }
}

# ---------------- Preflight ----------------
Write-Status "Microsoft 365 companion apps check on $env:COMPUTERNAME (mode: $(if ($Remediate) {'Remediate'} else {'Report'}))"
if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
    Write-Status "Appx module not available (Server Core / unsupported SKU). Nothing to do." "WARN"
    exit 0
}
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$os  = Get-CimInstance Win32_OperatingSystem
$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$c2rVersion = if ($c2r -and ($c2r.PSObject.Properties.Name -contains 'VersionToReport')) { $c2r.VersionToReport } else { 'not installed' }
Add-Result 'Context' 'INFO' ("{0} build {1}; M365 Apps C2R: {2}" -f $os.Caption, $os.BuildNumber, $c2rVersion)

# ---------------- Detect ----------------
$state = Get-CompanionState
foreach ($r in $state.Registered) {
    $users = @()
    try { $users = @($r.PackageUserInformation | ForEach-Object { "{0}:{1}" -f $_.UserSecurityId.Username, $_.InstallState }) } catch { $users = @('n/a') }
    Add-Result 'RegisteredPackage' 'PRESENT' ("{0} users=[{1}]" -f $r.PackageFullName, ($users -join '; '))
    Write-Status "Registered: $($r.PackageFullName)" "WARN"
}
foreach ($p in $state.Provisioned) {
    Add-Result 'ProvisionedPackage' 'PRESENT' $p.PackageName
    Write-Status "Provisioned: $($p.PackageName)" "WARN"
}
foreach ($d in $state.DataFolders) {
    Add-Result 'DataFolder' 'PRESENT' $d
    Write-Status "Data folder: $d" "INFO"
}
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and $_.Path -like "*\WindowsApps\$PackageName*" } catch { $false }
})
if ($procs.Count -gt 0) {
    Add-Result 'RunningProcess' 'PRESENT' (($procs | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ')
    Write-Status "Companion processes running — removal may defer until sign-out/restart" "WARN"
}

$needsAction = ($state.Registered.Count + $state.Provisioned.Count) -gt 0

# ---------------- Execute ----------------
if ($Remediate -and ($needsAction -or $state.DataFolders.Count -gt 0)) {
    foreach ($r in $state.Registered) {
        try {
            Remove-AppxPackage -Package $r.PackageFullName -AllUsers -ErrorAction Stop
            Add-Result 'RemoveRegistered' 'OK' $r.PackageFullName
            Write-Status "Removed registration $($r.PackageFullName)" "OK"
        } catch {
            Add-Result 'RemoveRegistered' 'ERROR' ("{0}: {1}" -f $r.PackageFullName, $_.Exception.Message)
            Write-Status "Remove-AppxPackage failed: $($_.Exception.Message)" "ERROR"
        }
    }
    foreach ($p in $state.Provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
            Add-Result 'RemoveProvisioned' 'OK' $p.PackageName
            Write-Status "Removed provisioned $($p.PackageName)" "OK"
        } catch {
            Add-Result 'RemoveProvisioned' 'ERROR' ("{0}: {1}" -f $p.PackageName, $_.Exception.Message)
            Write-Status "Remove-AppxProvisionedPackage failed: $($_.Exception.Message)" "ERROR"
        }
    }
    if (-not $KeepDataFolders) {
        foreach ($d in $state.DataFolders) {
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                Add-Result 'RemoveDataFolder' 'OK' $d
            } catch {
                Add-Result 'RemoveDataFolder' 'WARN' ("{0}: {1}" -f $d, $_.Exception.Message)
            }
        }
    }
}

# ---------------- Validate ----------------
$after = Get-CompanionState
$remaining = $after.Registered.Count + $after.Provisioned.Count
if ($Remediate) {
    if ($remaining -eq 0) {
        Add-Result 'Validate' 'CLEAN' 'No registered or provisioned package remains'
        Write-Status "Validation: CLEAN" "OK"
    } else {
        Add-Result 'Validate' 'PENDING' "$remaining object(s) remain — likely in use; sign out/restart and re-run"
        Write-Status "Validation: $remaining object(s) remain (in use?) — sign out/restart and re-run" "WARN"
    }
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath ("CompanionApps_{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Report: $csv"

if ($remaining -gt 0) {
    Write-Output "Microsoft 365 companion apps present ($remaining object(s))."
    exit 1
}
Write-Output "Microsoft 365 companion apps not present."
exit 0
