<#
.SYNOPSIS
    Reports Windows Driver Update for Business (WDfB) policy state and local driver update conflicts.

.DESCRIPTION
    Combines a local device-side check (WSUS remnants, driver update CSP registry state, recent PnP/
    driver install events) with a Graph-side check of Intune Driver Update Management (DUM) policy
    assignment and per-device driver approval status. Automates the diagnostic steps described in
    Intune/Troubleshooting/DriverManagement-A.md (How It Works / Validation Steps) so an engineer can
    quickly see whether a device is blocked by a WSUS conflict, missing policy, or a specific pending/
    declined driver.

    This script does NOT approve, pause, or decline any drivers, does NOT modify DUM policies, and does
    NOT remove WSUS registry keys. It is read-only reporting — remediation must be applied manually or
    via a separate script (see DriverManagement-A.md Remediation Playbooks).

.PARAMETER DeviceName
    Optional filter — only report Graph-side driver policy state for devices whose display name
    matches this wildcard pattern (e.g. "LT-ENG-*"). Default: all devices with a DUM policy assignment.

.PARAMETER SkipLocalCheck
    Switch. Skip the local device-side checks (registry, event log). Use when running remotely
    against Graph only.

.PARAMETER OutputPath
    Path for CSV export of the Graph-side per-device driver policy state. Defaults to
    .\DriverManagementStatus_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-DriverManagementStatus.ps1

.EXAMPLE
    .\Get-DriverManagementStatus.ps1 -DeviceName "LT-ENG-*" -SkipLocalCheck

.NOTES
    Requires: Microsoft.Graph.Authentication module (uses Invoke-MgGraphRequest against the beta
    endpoint for deviceManagement/windowsDriverUpdateProfiles).
    Requires Graph scope: DeviceManagementConfiguration.Read.All
    Run-as (local check portion): local administrator on the target device.
    Safe: Yes — fully read-only against Microsoft Graph, local registry, and event log.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeviceName = "*",

    [Parameter(Mandatory = $false)]
    [switch]$SkipLocalCheck,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\DriverManagementStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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
# LOCAL DEVICE-SIDE CHECK (skip with -SkipLocalCheck)
# ---------------------------------------------------------------------------
if (-not $SkipLocalCheck) {
    Write-Status "===== LOCAL DRIVER POLICY / CONFLICT CHECK =====" "OK"

    $wuPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    if (Test-Path $wuPolicyPath) {
        $wuPolicy = Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue
        if ($wuPolicy.PSObject.Properties.Name -contains "WUServer" -or $wuPolicy.PSObject.Properties.Name -contains "WUStatusServer") {
            Write-Status "WSUS remnant policy detected (WUServer/WUStatusServer set). This can block WDfB driver delivery. See DriverManagement-A.md — WSUS conflict remediation." "WARN"
        }
        else {
            Write-Status "No WSUS remnant (WUServer/WUStatusServer) found in WindowsUpdate policy key." "OK"
        }

        if ($wuPolicy.PSObject.Properties.Name -contains "ExcludeWUDriversInQualityUpdate" -and $wuPolicy.ExcludeWUDriversInQualityUpdate -eq 1) {
            Write-Status "ExcludeWUDriversInQualityUpdate = 1 — WU-delivered drivers are explicitly blocked by policy on this device." "WARN"
        }
    }
    else {
        Write-Status "No WindowsUpdate policy key found — device is likely using default (unmanaged) driver update behaviour." "INFO"
    }

    $dmClientUpdatePath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
    if (Test-Path $dmClientUpdatePath) {
        $dmClient = Get-ItemProperty -Path $dmClientUpdatePath -ErrorAction SilentlyContinue
        Write-Status "DMClient Update policy values present — device is receiving MDM update/driver policy." "OK"
        $dmClient | Select-Object * -ExcludeProperty PS* | Format-List
    }
    else {
        Write-Status "No DMClient Update policy values found. Device may not have received Intune update/driver policy yet." "WARN"
    }

    Write-Status "Checking recent PnP driver binding events (last 24h)..."
    try {
        $pnpEvents = Get-WinEvent -LogName "Microsoft-Windows-Kernel-PnP/Configuration" -MaxEvents 20 -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-24) }
        if ($pnpEvents) {
            Write-Status "Found $($pnpEvents.Count) recent PnP configuration event(s):" "INFO"
            $pnpEvents | Select-Object TimeCreated, Id, LevelDisplayName, Message | Select-Object -First 10 | Format-Table -AutoSize -Wrap
        }
        else {
            Write-Status "No recent PnP configuration events in the last 24 hours." "OK"
        }
    }
    catch {
        Write-Status "Could not read Microsoft-Windows-Kernel-PnP/Configuration log: $($_.Exception.Message)" "WARN"
    }

    Write-Status "Checking Windows Update client operational log for driver install activity (last 20 events)..."
    try {
        $wuEvents = Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match "driver" }
        if ($wuEvents) {
            $wuEvents | Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap
        }
        else {
            Write-Status "No driver-related entries in the last 20 WindowsUpdateClient operational events." "INFO"
        }
    }
    catch {
        Write-Status "Could not read Microsoft-Windows-WindowsUpdateClient/Operational log: $($_.Exception.Message)" "WARN"
    }

    Write-Host ""
}
else {
    Write-Status "Skipping local device-side check (-SkipLocalCheck specified)." "INFO"
}

# ---------------------------------------------------------------------------
# PREFLIGHT — GRAPH
# ---------------------------------------------------------------------------
Write-Status "===== GRAPH-SIDE DRIVER UPDATE MANAGEMENT (DUM) CHECK =====" "OK"
Write-Status "Checking for required Microsoft Graph module..."
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Module 'Microsoft.Graph.Authentication' not found. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "ERROR"
    throw "Missing required module: Microsoft.Graph.Authentication"
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Microsoft Graph. Connecting..." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" | Out-Null
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
# DETECT — locate Driver Update Management profiles
# ---------------------------------------------------------------------------
Write-Status "Retrieving Windows Driver Update (DUM) profiles..."
try {
    $profiles = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles").value
}
catch {
    Write-Status "Failed to query windowsDriverUpdateProfiles: $($_.Exception.Message)" "ERROR"
    throw
}

if (-not $profiles -or $profiles.Count -eq 0) {
    Write-Status "No Driver Update Management profiles found in this tenant. Confirm profiles exist under Intune > Devices > Windows > Driver updates." "WARN"
    return
}
Write-Status "Found $($profiles.Count) DUM profile(s): $($profiles.displayName -join ', ')" "OK"

# ---------------------------------------------------------------------------
# EXECUTE — per-profile device deployment states + pending driver inventory
# ---------------------------------------------------------------------------
$deviceResults = [System.Collections.Generic.List[object]]::new()
$driverInventory = [System.Collections.Generic.List[object]]::new()

foreach ($profile in $profiles) {
    Write-Status "Checking device states for profile: $($profile.displayName)..."
    try {
        $deviceStatesUri = "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles/$($profile.id)/deviceStatuses"
        $deviceStates = (Invoke-MgGraphRequest -Method GET -Uri $deviceStatesUri).value
    }
    catch {
        Write-Status "  Could not retrieve device statuses for '$($profile.displayName)': $($_.Exception.Message)" "WARN"
        $deviceStates = @()
    }

    foreach ($ds in $deviceStates) {
        if ($DeviceName -ne "*" -and $ds.deviceDisplayName -notlike $DeviceName) { continue }

        $flag = switch ($ds.status) {
            "success" { "OK" }
            "error"   { "ERROR — check WSUS conflict / policy assignment" }
            "conflict" { "CONFLICT — overlapping driver policy or GPO" }
            "pending" { "PENDING — check sync timing / assignment scope" }
            default   { "Unknown status: $($ds.status)" }
        }

        $deviceResults.Add([PSCustomObject]@{
            ProfileName   = $profile.displayName
            ProfileId     = $profile.id
            DeviceName    = $ds.deviceDisplayName
            UserPrincipal = $ds.userPrincipalName
            Status        = $ds.status
            LastReported  = $ds.lastReportedDateTime
            Flag          = $flag
        })
    }

    Write-Status "Checking pending/declined driver inventory for profile: $($profile.displayName)..."
    try {
        $inventoryUri = "https://graph.microsoft.com/beta/deviceManagement/windowsDriverUpdateProfiles/$($profile.id)/driverInventories"
        $inventory = (Invoke-MgGraphRequest -Method GET -Uri $inventoryUri).value
        foreach ($drv in $inventory) {
            $driverInventory.Add([PSCustomObject]@{
                ProfileName    = $profile.displayName
                DriverName     = $drv.name
                Manufacturer   = $drv.manufacturer
                Version        = $drv.version
                ApprovalStatus = $drv.approvalStatus
                Category       = $drv.category
            })
        }
    }
    catch {
        Write-Status "  Could not retrieve driver inventory for '$($profile.displayName)': $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "===== DRIVER UPDATE MANAGEMENT SUMMARY =====" "OK"

if ($deviceResults.Count -gt 0) {
    $errors = @($deviceResults | Where-Object { $_.Status -eq "error" })
    $pending = @($deviceResults | Where-Object { $_.Status -eq "pending" })
    Write-Status "Total device-profile rows: $($deviceResults.Count)"
    Write-Status "Error:   $($errors.Count)" $(if ($errors.Count -gt 0) { "ERROR" } else { "OK" })
    Write-Status "Pending: $($pending.Count)" $(if ($pending.Count -gt 0) { "WARN" } else { "OK" })
    $deviceResults | Where-Object { $_.Status -ne "success" } | Format-Table ProfileName, DeviceName, Status, Flag -AutoSize
}
else {
    Write-Status "No device status rows matched the given filter." "WARN"
}

if ($driverInventory.Count -gt 0) {
    $pendingDrivers = @($driverInventory | Where-Object { $_.ApprovalStatus -eq "needsReview" -or $_.ApprovalStatus -eq "declined" })
    if ($pendingDrivers.Count -gt 0) {
        Write-Status "$($pendingDrivers.Count) driver(s) awaiting review or declined — these will not install until approved:" "WARN"
        $pendingDrivers | Format-Table DriverName, Manufacturer, Version, ApprovalStatus -AutoSize
    }
    else {
        Write-Status "No drivers currently pending review or declined." "OK"
    }
}

try {
    $deviceResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Device status report exported to: $OutputPath" "OK"
    if ($driverInventory.Count -gt 0) {
        $inventoryPath = $OutputPath -replace '\.csv$', '_DriverInventory.csv'
        $driverInventory | Export-Csv -Path $inventoryPath -NoTypeInformation -Encoding UTF8
        Write-Status "Driver inventory exported to: $inventoryPath" "OK"
    }
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
