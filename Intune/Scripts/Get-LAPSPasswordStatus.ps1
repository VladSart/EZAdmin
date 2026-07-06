<#
.SYNOPSIS
    Audits Windows LAPS rotation health across Intune-managed devices via Microsoft Graph.

.DESCRIPTION
    Connects to Microsoft Graph and, for each targeted device (or all managed Windows devices),
    reports: whether a LAPS local admin password is retrievable, when it was last backed up/rotated,
    the account name LAPS is managing, and whether the device appears to still have a legacy LAPS
    (AdmPwd CSE) footprint that would conflict with Windows LAPS. This automates the checks documented
    in Intune/Troubleshooting/LAPS-B.md and LAPS-A.md so triage doesn't require manually querying
    Graph per device.

    This script does NOT rotate passwords, does NOT display the plaintext password value by default
    (use -RevealPassword to opt in, and only do so on an as-needed basis), and does NOT modify any
    policy. It is read-only reporting.

    Legacy LAPS CSE detection is remote-registry based and requires WinRM/PSRemoting connectivity to
    the device; if unreachable, that column reports "Unknown" rather than failing the whole run.

.PARAMETER DeviceName
    One or more Intune device names to check. If omitted, checks all Windows managed devices
    (can be slow on large tenants — consider piping a filtered list).

.PARAMETER RevealPassword
    Switch. If set, includes the retrieved plaintext LAPS password in console output and CSV.
    Off by default — treat this flag as sensitive-data handling, not a convenience toggle.

.PARAMETER CheckLegacyLAPS
    Switch. If set, attempts a remote registry check on each device for the legacy LAPS CSE GUID.
    Requires PSRemoting/WinRM reachability to the device.

.PARAMETER OutputPath
    Path for CSV export. Defaults to .\LAPSPasswordStatus_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-LAPSPasswordStatus.ps1 -DeviceName "DESKTOP-AB12CD"

.EXAMPLE
    .\Get-LAPSPasswordStatus.ps1 -CheckLegacyLAPS -OutputPath C:\Reports\laps.csv

.EXAMPLE
    .\Get-LAPSPasswordStatus.ps1 -RevealPassword
    # Only use when actively retrieving a password for a helpdesk action — do not run routinely with this flag.

.NOTES
    Requires: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Authentication modules
    Requires Graph scope: DeviceManagementManagedDevices.Read.All (and appropriate directory role —
    Cloud Device Administrator or Intune Administrator — to actually read LAPS passwords; see LAPS-B.md Fix 3)
    Run-as: Any account with the above Graph permissions. No local admin needed unless -CheckLegacyLAPS is used.
    Safe: Yes — read-only. -RevealPassword surfaces sensitive data to console/CSV; handle output accordingly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$DeviceName,

    [Parameter(Mandatory = $false)]
    [switch]$RevealPassword,

    [Parameter(Mandatory = $false)]
    [switch]$CheckLegacyLAPS,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\LAPSPasswordStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------------------
Write-Status "Checking for required Microsoft Graph modules..."
$requiredModules = @("Microsoft.Graph.DeviceManagement", "Microsoft.Graph.Authentication")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        throw "Missing required module: $mod"
    }
}
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Microsoft Graph. Connecting..." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" | Out-Null
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) (tenant $($context.TenantId))" "OK"
    }
}
catch {
    Write-Status "Failed to establish Graph connection: $($_.Exception.Message)" "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# DETECT — resolve target device list
# ---------------------------------------------------------------------------
Write-Status "Resolving target devices..."
$devices = @()

if ($DeviceName) {
    foreach ($name in $DeviceName) {
        $found = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$name' and operatingSystem eq 'Windows'" -All
        if (-not $found) {
            Write-Status "Device '$name' not found or not Windows — skipping" "WARN"
            continue
        }
        $devices += $found
    }
}
else {
    Write-Status "No -DeviceName specified — pulling all Windows managed devices (this may take a while)..." "WARN"
    $devices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All
}

if (-not $devices -or $devices.Count -eq 0) {
    Write-Status "No matching Windows devices found. Exiting." "ERROR"
    return
}
Write-Status "Found $($devices.Count) device(s) to check." "OK"

# ---------------------------------------------------------------------------
# EXECUTE — per-device LAPS status
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$counter = 0

foreach ($device in $devices) {
    $counter++
    Write-Status "[$counter/$($devices.Count)] Checking $($device.DeviceName)..."

    $row = [PSCustomObject]@{
        DeviceName          = $device.DeviceName
        IntuneDeviceId      = $device.Id
        AzureADDeviceId     = $device.AzureAdDeviceId
        ComplianceState     = $device.ComplianceState
        LastSyncDateTime    = $device.LastSyncDateTime
        LAPSAccountName     = $null
        LAPSBackupDateTime  = $null
        LAPSPasswordFound   = $false
        LAPSPassword        = $null
        LegacyLAPSDetected  = "Not Checked"
        Notes               = ""
    }

    try {
        $lapsResult = Get-MgDeviceManagementManagedDeviceLocalAdminPassword -ManagedDeviceId $device.Id -ErrorAction Stop
        if ($lapsResult) {
            $row.LAPSPasswordFound  = $true
            $row.LAPSAccountName    = $lapsResult.AdditionalProperties['accountName']
            $row.LAPSBackupDateTime = $lapsResult.AdditionalProperties['passwordExpirationDateTime']
            if ($RevealPassword) {
                $row.LAPSPassword = $lapsResult.AdditionalProperties['password']
            }
            else {
                $row.LAPSPassword = "(hidden — use -RevealPassword to show)"
            }
            $row.Notes = "Password retrievable"
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match "Forbidden|403|Authorization_RequestDenied") {
            $row.Notes = "Permission denied — caller lacks LAPS Read role (see LAPS-B.md Fix 3)"
        }
        elseif ($msg -match "NotFound|404") {
            $row.Notes = "No LAPS password on record — device hasn't rotated yet, or LAPS not applied"
        }
        else {
            $row.Notes = "Error: $msg"
        }
    }

    if ($CheckLegacyLAPS) {
        try {
            $legacyKeyPath = "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}"
            $regCheck = Invoke-Command -ComputerName $device.DeviceName -ErrorAction Stop -ScriptBlock {
                param($path)
                Test-Path "HKLM:\$path"
            } -ArgumentList $legacyKeyPath
            $row.LegacyLAPSDetected = if ($regCheck) { "YES — conflict likely" } else { "No" }
        }
        catch {
            $row.LegacyLAPSDetected = "Unknown (unreachable: $($_.Exception.Message))"
        }
    }

    $results.Add($row)
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
$found     = @($results | Where-Object { $_.LAPSPasswordFound })
$notFound  = @($results | Where-Object { -not $_.LAPSPasswordFound })
$legacyHit = @($results | Where-Object { $_.LegacyLAPSDetected -like "YES*" })

Write-Host ""
Write-Status "===== LAPS STATUS SUMMARY =====" "OK"
Write-Status "Devices checked:            $($results.Count)"
Write-Status "Password retrievable:       $($found.Count)" "OK"
Write-Status "No password / denied:       $($notFound.Count)" $(if ($notFound.Count -gt 0) { "WARN" } else { "OK" })
if ($CheckLegacyLAPS) {
    Write-Status "Legacy LAPS CSE detected:   $($legacyHit.Count)" $(if ($legacyHit.Count -gt 0) { "WARN" } else { "OK" })
}

$results | Format-Table DeviceName, ComplianceState, LAPSPasswordFound, LAPSBackupDateTime, LegacyLAPSDetected, Notes -AutoSize

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
