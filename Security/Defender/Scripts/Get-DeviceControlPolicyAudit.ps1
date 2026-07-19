<#
.SYNOPSIS
    Audits local Defender for Endpoint Device Control readiness and device inventory for
    cross-referencing against Intune device control policy groups.

.DESCRIPTION
    Companion diagnostic to Security/Defender/DeviceControl-A.md and -B.md.
    Collects, in a single pass:
      - Defender onboarding state and anti-malware client version (device control requires >= 4.18.2103.3)
      - Whether a device control policy has actually been delivered to the device (registry presence)
      - Full PnP device inventory for DiskDrive / WPD / Printer classes, including Hardware IDs and
        Instance Paths — the exact properties needed to cross-check against Intune reusable settings
        groups (VID_PID, SerialNumberId, InstancePathId, FriendlyNameId)
      - Windows Device Installation Restriction registry state — the separate, easily-confused
        ADMX/GPO/CSP layer that blocks at install-time rather than access-time

    This script does NOT query Advanced Hunting (that requires Graph/Defender API auth and is
    the authoritative source for which policy *name* actually decided a verdict — see the
    runbook's Evidence Pack section for the Advanced Hunting query to run centrally). This script
    only covers what's visible locally on the device.

    This script is read-only / reporting only. It does not create, modify, or remove any policy,
    group, rule, or entry.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: $env:TEMP.

.EXAMPLE
    .\Get-DeviceControlPolicyAudit.ps1
    Runs a full local device control readiness and inventory audit.

.EXAMPLE
    .\Get-DeviceControlPolicyAudit.ps1 -OutputPath C:\Temp\Evidence
    Writes the CSV report to a custom folder.

.NOTES
    Requires: Run as Administrator (registry and some PnP property queries need elevation).
    Safe: Read-only. No configuration changes are made.
    Companion runbooks: Security/Defender/DeviceControl-A.md (deep dive),
                         Security/Defender/DeviceControl-B.md (hotfix triage).
#>
[CmdletBinding()]
param(
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "Not running as Administrator — registry and some PnP property queries may fail or return incomplete data." "WARN"
}

$summary = [System.Collections.Generic.List[pscustomobject]]::new()
function Add-Summary {
    param($Check, $Value, $Status)
    $summary.Add([pscustomobject]@{ Check = $Check; Value = $Value; Status = $Status })
}

# ============================================================
# LAYER 1 — Defender onboarding and anti-malware client version
# ============================================================
Write-Status "Checking Defender onboarding and client version..." "INFO"
try {
    $mpStatus = Get-MpComputerStatus
    $minVersion = [version]"4.18.2103.3"
    $currentVersion = $null
    try { $currentVersion = [version]$mpStatus.AMProductVersion } catch { }

    Add-Summary "AMProductVersion" $mpStatus.AMProductVersion `
        (if ($currentVersion -and $currentVersion -ge $minVersion) { "OK" } else { "WARN — below documented device control minimum 4.18.2103.3" })
    Add-Summary "AMServiceEnabled" $mpStatus.AMServiceEnabled (if ($mpStatus.AMServiceEnabled) { "OK" } else { "FAIL" })
    Add-Summary "OS is Windows Server (device control NOT supported)" ([bool](Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) "INFO"
} catch {
    Add-Summary "Get-MpComputerStatus" "ERROR: $($_.Exception.Message)" "ERROR"
}

# ============================================================
# LAYER 2 — Device control policy delivery
# ============================================================
Write-Status "Checking for locally-delivered Device Control policy..." "INFO"
$dcPath = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Device Control"
if (Test-Path $dcPath) {
    Add-Summary "Device Control policy key present" $true "OK"
    try {
        $dcValues = Get-ItemProperty -Path $dcPath -ErrorAction SilentlyContinue
        if ($dcValues) {
            Add-Summary "Device Control policy value count" (($dcValues.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }).Count) "INFO"
        }
    } catch { }
} else {
    Add-Summary "Device Control policy key present" $false "WARN — no policy delivered yet, or device control not assigned to this device"
}

# ============================================================
# LAYER 3 — Windows Device Installation Restrictions (separate layer)
# ============================================================
Write-Status "Checking Windows Device Installation Restrictions (separate from Defender device control)..." "INFO"
$dirPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
if (Test-Path $dirPath) {
    $dirValues = Get-ItemProperty -Path $dirPath -ErrorAction SilentlyContinue
    Add-Summary "Device Installation Restrictions configured" $true "WARN — a separate install-time block layer is active; rule this in/out before diagnosing Defender device control"
    if ($dirValues) {
        ($dirValues.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) | ForEach-Object {
            Add-Summary "  DeviceInstall\Restrictions\$($_.Name)" $_.Value "INFO"
        }
    }
} else {
    Add-Summary "Device Installation Restrictions configured" $false "OK — this separate layer is not in play"
}

# ============================================================
# LAYER 4 — PnP device inventory (cross-reference source for group authoring)
# ============================================================
Write-Status "Enumerating PnP devices in device-control scope (DiskDrive, WPD, Printer)..." "INFO"
$deviceInventory = [System.Collections.Generic.List[pscustomobject]]::new()
try {
    $devices = Get-PnpDevice -Class DiskDrive, WPD, Printer -ErrorAction SilentlyContinue
    foreach ($d in $devices) {
        $hwIds = $null
        $instancePath = $d.InstanceId
        try {
            $hwIds = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName "DEVPKEY_Device_HardwareIds" -ErrorAction SilentlyContinue).Data -join "; "
        } catch { }

        $deviceInventory.Add([pscustomobject]@{
            FriendlyName  = $d.FriendlyName
            Class         = $d.Class
            Status        = $d.Status
            InstancePathId = $instancePath
            HardwareIds   = $hwIds
        })
    }
    Add-Summary "PnP devices found in scope (DiskDrive/WPD/Printer)" $deviceInventory.Count "INFO"
} catch {
    Add-Summary "PnP device enumeration" "ERROR: $($_.Exception.Message)" "ERROR"
}

# Flag devices in an error/problem state — may indicate a Device Installation Restriction block
$problemDevices = $deviceInventory | Where-Object { $_.Status -notin @("OK") }
if ($problemDevices) {
    Add-Summary "Devices in non-OK state (possible install-time block)" ($problemDevices.FriendlyName -join "; ") "WARN"
}

# ============================================================
# REPORT
# ============================================================
Write-Host "`n=== DEVICE CONTROL READINESS SUMMARY ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize -Wrap

Write-Host "`n=== PNP DEVICE INVENTORY (cross-reference against Intune reusable settings groups) ===" -ForegroundColor Cyan
$deviceInventory | Format-Table -AutoSize -Wrap

$failCount = ($summary | Where-Object { $_.Status -like "FAIL*" }).Count
$warnCount = ($summary | Where-Object { $_.Status -like "WARN*" }).Count
Write-Status "$failCount FAIL, $warnCount WARN out of $($summary.Count) checks." (if ($failCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryCsv = Join-Path $OutputPath "DeviceControlReadiness-$env:COMPUTERNAME-$timestamp.csv"
$inventoryCsv = Join-Path $OutputPath "DeviceControlInventory-$env:COMPUTERNAME-$timestamp.csv"
$summary | Export-Csv -Path $summaryCsv -NoTypeInformation
$deviceInventory | Export-Csv -Path $inventoryCsv -NoTypeInformation
Write-Status "Reports exported to: $summaryCsv and $inventoryCsv" "OK"

Write-Status "NOTE: For the authoritative 'which policy actually decided' verdict, run the Advanced Hunting query in DeviceControl-A.md's Evidence Pack section against the Defender portal — this script only covers local device state." "INFO"
