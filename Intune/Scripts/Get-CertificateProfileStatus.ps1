<#
.SYNOPSIS
    Reports SCEP/PKCS certificate profile delivery status for Intune-managed devices via Microsoft Graph.

.DESCRIPTION
    Pulls device configuration states for certificate profiles (SCEP, PKCS, Trusted Certificate) from
    Microsoft Graph and flags devices where delivery is Failed, Pending longer than a threshold, or in
    Conflict. This automates Step 2 ("Check Intune device certificate report") and part of the triage
    table from Intune/Troubleshooting/Certificates-B.md, so an engineer doesn't have to click through
    Devices → [Device] → Monitor → Certificate details one device at a time.

    This script is read-only against Graph. It does NOT restart connector services, does NOT touch the
    NDES/PKCS connector servers, and does NOT modify certificate profiles or assignments. On-prem
    connector/NDES health (Fixes 1-3 in Certificates-B.md) still requires separate checks against those
    servers — this script only covers the Intune-side delivery state.

.PARAMETER DeviceName
    One or more Intune device names to check. If omitted, checks all managed devices with at least
    one certificate-type configuration state.

.PARAMETER PendingThresholdHours
    Number of hours a profile can sit in "Pending" before this script flags it as stale. Default: 4.

.PARAMETER OutputPath
    Path for CSV export. Defaults to .\CertificateProfileStatus_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-CertificateProfileStatus.ps1

.EXAMPLE
    .\Get-CertificateProfileStatus.ps1 -DeviceName "LAPTOP-001","LAPTOP-002" -PendingThresholdHours 2

.NOTES
    Requires: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Authentication modules
    Requires Graph scope: DeviceManagementConfiguration.Read.All
    Run-as: Any account with the above Graph permission — no local/on-prem admin rights needed.
    Safe: Yes — fully read-only against Microsoft Graph.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$DeviceName,

    [Parameter(Mandatory = $false)]
    [int]$PendingThresholdHours = 4,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\CertificateProfileStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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
# DETECT — resolve target device list
# ---------------------------------------------------------------------------
Write-Status "Resolving target devices..."
$devices = @()

if ($DeviceName) {
    foreach ($name in $DeviceName) {
        $found = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$name'" -All
        if (-not $found) {
            Write-Status "Device '$name' not found — skipping" "WARN"
            continue
        }
        $devices += $found
    }
}
else {
    Write-Status "No -DeviceName specified — pulling all managed devices (this may take a while)..." "WARN"
    $devices = Get-MgDeviceManagementManagedDevice -All
}

if (-not $devices -or $devices.Count -eq 0) {
    Write-Status "No matching devices found. Exiting." "ERROR"
    return
}
Write-Status "Found $($devices.Count) device(s) to check." "OK"

# Certificate-related profile name patterns to match (SCEP, PKCS, Trusted/Root cert profiles)
$certPatterns = @("*cert*", "*scep*", "*pkcs*", "*trusted*")

# ---------------------------------------------------------------------------
# EXECUTE — per-device certificate configuration state
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$counter = 0
$now = Get-Date

foreach ($device in $devices) {
    $counter++
    Write-Status "[$counter/$($devices.Count)] Checking $($device.DeviceName)..."

    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device.Id)/deviceConfigurationStates"
        $states = (Invoke-MgGraphRequest -Method GET -Uri $uri).value

        $certStates = $states | Where-Object {
            $displayName = $_.displayName
            $isCertProfile = $false
            foreach ($pattern in $certPatterns) {
                if ($displayName -like $pattern) { $isCertProfile = $true; break }
            }
            $isCertProfile
        }

        if (-not $certStates -or $certStates.Count -eq 0) {
            $results.Add([PSCustomObject]@{
                DeviceName       = $device.DeviceName
                IntuneDeviceId   = $device.Id
                ProfileName      = "(none found)"
                State            = "N/A"
                ErrorCount       = 0
                ConflictCount    = 0
                Flag             = "No certificate profiles targeted at this device"
                LastSyncDateTime = $device.LastSyncDateTime
            })
            continue
        }

        foreach ($cs in $certStates) {
            $flag = "OK"
            $stateVal = $cs.state
            $syncAgeHours = if ($device.LastSyncDateTime) {
                [math]::Round((New-TimeSpan -Start $device.LastSyncDateTime -End $now).TotalHours, 1)
            } else { $null }

            if ($stateVal -eq "error") {
                $flag = "FAILED — see connector/NDES logs (Certificates-B.md Fixes 1-3)"
            }
            elseif ($stateVal -eq "conflict") {
                $flag = "CONFLICT — check profile ordering / subject name overlap"
            }
            elseif ($stateVal -in @("pending", "notApplicable") -and $syncAgeHours -ne $null -and $syncAgeHours -ge $PendingThresholdHours) {
                $flag = "STALE PENDING (last sync ${syncAgeHours}h ago) — force sync (Certificates-B.md Fix 4)"
            }
            elseif ($stateVal -eq "success") {
                $flag = "OK"
            }
            else {
                $flag = "Review — state: $stateVal"
            }

            $results.Add([PSCustomObject]@{
                DeviceName       = $device.DeviceName
                IntuneDeviceId   = $device.Id
                ProfileName      = $cs.displayName
                State            = $stateVal
                ErrorCount       = $cs.errorCount
                ConflictCount    = $cs.conflictCount
                Flag             = $flag
                LastSyncDateTime = $device.LastSyncDateTime
            })
        }
    }
    catch {
        $results.Add([PSCustomObject]@{
            DeviceName       = $device.DeviceName
            IntuneDeviceId   = $device.Id
            ProfileName      = "(query failed)"
            State            = "Unknown"
            ErrorCount       = $null
            ConflictCount    = $null
            Flag             = "Graph query error: $($_.Exception.Message)"
            LastSyncDateTime = $device.LastSyncDateTime
        })
    }
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
$failed   = @($results | Where-Object { $_.Flag -like "FAILED*" })
$conflict = @($results | Where-Object { $_.Flag -like "CONFLICT*" })
$stale    = @($results | Where-Object { $_.Flag -like "STALE*" })
$ok       = @($results | Where-Object { $_.Flag -eq "OK" })

Write-Host ""
Write-Status "===== CERTIFICATE PROFILE STATUS SUMMARY =====" "OK"
Write-Status "Total profile-device rows:  $($results.Count)"
Write-Status "OK:                         $($ok.Count)" "OK"
Write-Status "Failed:                     $($failed.Count)" $(if ($failed.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Conflict:                   $($conflict.Count)" $(if ($conflict.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Stale pending:              $($stale.Count)" $(if ($stale.Count -gt 0) { "WARN" } else { "OK" })

if ($failed.Count -gt 0 -or $conflict.Count -gt 0 -or $stale.Count -gt 0) {
    Write-Host ""
    Write-Status "Devices needing attention:" "WARN"
    $results | Where-Object { $_.Flag -ne "OK" -and $_.Flag -notlike "No certificate*" } |
        Format-Table DeviceName, ProfileName, State, Flag -AutoSize
}

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
