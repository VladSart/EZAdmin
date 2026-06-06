
<#
.SYNOPSIS
    Forces an Intune MDM sync on one or more managed Windows devices.

.DESCRIPTION
    Triggers an immediate MDM sync cycle on target devices using one of three methods:
      1. Remote: Graph API device action (requires DeviceManagementManagedDevices.ReadWrite.All)
      2. Local:  Calls the built-in ScheduledTask or MdmAgent API (run on device itself)
      3. Bulk:   Accepts pipeline input or a CSV of device IDs for fleet-wide sync pushes

    Safe to run repeatedly. Does not alter policy assignments or device configuration.
    Graph API remote sync may take 5–15 minutes to be reflected in portal.

.PARAMETER DeviceName
    Display name of the Intune managed device (supports wildcards for local lookup).

.PARAMETER DeviceId
    Intune managed device ID (GUID). Use instead of DeviceName for precision.

.PARAMETER CsvPath
    Path to a CSV file with a 'DeviceId' column — for bulk remote sync.

.PARAMETER Local
    Run a local sync on THIS machine (no Graph auth required). Useful from a remote session.

.PARAMETER TenantId
    Azure AD tenant ID. Required for remote Graph API sync.

.PARAMETER ClientId
    App registration client ID with DeviceManagementManagedDevices.ReadWrite.All permission.

.PARAMETER ClientSecret
    App registration client secret. Use -Credential for interactive if preferred.

.EXAMPLE
    # Sync a single device by name via Graph
    .\Invoke-IntuneSync.ps1 -DeviceName "DESKTOP-ABC123" -TenantId "contoso.onmicrosoft.com" -ClientId "<appId>" -ClientSecret "<secret>"

.EXAMPLE
    # Sync this machine locally (run on the device)
    .\Invoke-IntuneSync.ps1 -Local

.EXAMPLE
    # Bulk sync from CSV
    .\Invoke-IntuneSync.ps1 -CsvPath "C:\Temp\devices.csv" -TenantId "<tenant>" -ClientId "<appId>" -ClientSecret "<secret>"

.NOTES
    Requires: Microsoft.Graph module OR raw REST calls (this script uses raw REST — no module dependency).
    Run-as: Administrator only required for -Local mode.
    Safe/Unsafe: SAFE — sync action is non-destructive.
    Graph permission: DeviceManagementManagedDevices.ReadWrite.All (Application or Delegated)
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(ParameterSetName = 'ByName', Mandatory)]
    [string]$DeviceName,

    [Parameter(ParameterSetName = 'ById', Mandatory)]
    [string]$DeviceId,

    [Parameter(ParameterSetName = 'Bulk', Mandatory)]
    [string]$CsvPath,

    [Parameter(ParameterSetName = 'Local', Mandatory)]
    [switch]$Local,

    [Parameter(ParameterSetName = 'ByName', Mandatory)]
    [Parameter(ParameterSetName = 'ById', Mandatory)]
    [Parameter(ParameterSetName = 'Bulk', Mandatory)]
    [string]$TenantId,

    [Parameter(ParameterSetName = 'ByName', Mandatory)]
    [Parameter(ParameterSetName = 'ById', Mandatory)]
    [Parameter(ParameterSetName = 'Bulk', Mandatory)]
    [string]$ClientId,

    [Parameter(ParameterSetName = 'ByName', Mandatory)]
    [Parameter(ParameterSetName = 'ById', Mandatory)]
    [Parameter(ParameterSetName = 'Bulk', Mandatory)]
    [string]$ClientSecret
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
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts][$Status] $Message" -ForegroundColor $colour
}

# ─────────────────────────────────────────────
# LOCAL MODE — run directly on the managed device
# ─────────────────────────────────────────────
if ($Local) {
    Write-Status "Local sync mode — triggering MDM sync on this machine"

    # Method 1: DeviceEnroller scheduled task (Windows 10/11)
    $taskPath = "\Microsoft\Windows\EnterpriseMgmt\"
    $tasks = Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue |
             Where-Object { $_.TaskName -like "*Schedule*to run OMADMClient*" -or
                            $_.TaskName -like "*DeviceEnroller*" }

    if ($tasks) {
        foreach ($task in $tasks) {
            Write-Status "Running scheduled task: $($task.TaskName)"
            Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
        }
        Write-Status "Scheduled task(s) triggered. Allow 2-5 minutes for sync." -Status "OK"
    } else {
        Write-Status "No DeviceEnroller tasks found — trying MdmAgent COM approach" -Status "WARN"

        # Method 2: Direct OMADMClient trigger via WMI/OMADM
        try {
            $session = New-CimSession
            $result = Invoke-CimMethod -Namespace "root\cimv2\mdm\dmmap" `
                                       -ClassName "MDM_Client" `
                                       -MethodName "ManualMDMEnrollment" `
                                       -CimSession $session `
                                       -ErrorAction Stop
            Write-Status "OMADMClient trigger returned: $($result.ReturnValue)" -Status "OK"
        } catch {
            Write-Status "COM trigger failed: $_" -Status "ERROR"
            Write-Status "Try running: Start-Process -FilePath 'deviceenroller.exe' -ArgumentList '/o' -Wait"
        }
    }

    # Show last sync time
    $lastSync = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LastMDMClientSyncTime -ErrorAction SilentlyContinue |
                Sort-Object -Descending |
                Select-Object -First 1
    if ($lastSync) {
        Write-Status "Last recorded MDM sync: $lastSync" -Status "INFO"
    }
    exit 0
}

# ─────────────────────────────────────────────
# GRAPH TOKEN
# ─────────────────────────────────────────────
function Get-GraphToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    Write-Status "Acquiring Graph token for tenant: $TenantId"
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $response  = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType "application/x-www-form-urlencoded"
    Write-Status "Token acquired (expires in $($response.expires_in)s)" -Status "OK"
    return $response.access_token
}

function Invoke-GraphSync {
    param([string]$ManagedDeviceId, [string]$Token)
    $uri     = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$ManagedDeviceId/syncDevice"
    $headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ErrorAction Stop
        return [PSCustomObject]@{ DeviceId = $ManagedDeviceId; Result = "Sync requested"; Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
    } catch {
        $errMsg = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ DeviceId = $ManagedDeviceId; Result = "ERROR: $($errMsg.error.message ?? $_)"; Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
    }
}

function Get-DeviceIdByName {
    param([string]$Name, [string]$Token)
    $encoded = [System.Web.HttpUtility]::UrlEncode($Name)
    $uri     = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$Name'&`$select=id,deviceName,lastSyncDateTime,complianceState"
    $headers = @{ Authorization = "Bearer $Token" }
    $result  = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    return $result.value
}

# ─────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────
$token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
$results = [System.Collections.Generic.List[object]]::new()

# ─────────────────────────────────────────────
# EXECUTE
# ─────────────────────────────────────────────
switch ($PSCmdlet.ParameterSetName) {

    'ByName' {
        Write-Status "Looking up device: $DeviceName"
        $devices = Get-DeviceIdByName -Name $DeviceName -Token $token
        if (-not $devices) {
            Write-Status "No Intune device found with name: $DeviceName" -Status "ERROR"
            exit 1
        }
        foreach ($d in $devices) {
            Write-Status "Syncing: $($d.deviceName) [$($d.id)] — last sync: $($d.lastSyncDateTime)"
            $r = Invoke-GraphSync -ManagedDeviceId $d.id -Token $token
            $r | Add-Member -NotePropertyName DeviceName -NotePropertyValue $d.deviceName
            Write-Status $r.Result -Status $(if ($r.Result -like "ERROR*") { "ERROR" } else { "OK" })
            $results.Add($r)
        }
    }

    'ById' {
        Write-Status "Syncing device ID: $DeviceId"
        $r = Invoke-GraphSync -ManagedDeviceId $DeviceId -Token $token
        Write-Status $r.Result -Status $(if ($r.Result -like "ERROR*") { "ERROR" } else { "OK" })
        $results.Add($r)
    }

    'Bulk' {
        if (-not (Test-Path $CsvPath)) {
            Write-Status "CSV not found: $CsvPath" -Status "ERROR"; exit 1
        }
        $rows = Import-Csv -Path $CsvPath
        if (-not ($rows | Get-Member -Name DeviceId -ErrorAction SilentlyContinue)) {
            Write-Status "CSV must have a 'DeviceId' column" -Status "ERROR"; exit 1
        }
        Write-Status "Processing $($rows.Count) devices from CSV"
        foreach ($row in $rows) {
            $r = Invoke-GraphSync -ManagedDeviceId $row.DeviceId -Token $token
            Write-Status "$($row.DeviceId) → $($r.Result)" -Status $(if ($r.Result -like "ERROR*") { "WARN" } else { "OK" })
            $results.Add($r)
            Start-Sleep -Milliseconds 200   # Graph throttle guard
        }
    }
}

# ─────────────────────────────────────────────
# REPORT
# ─────────────────────────────────────────────
$csvOut = "IntuneSync_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
$results | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
Write-Status "Results saved → $csvOut" -Status "OK"

$errors = $results | Where-Object { $_.Result -like "ERROR*" }
if ($errors) {
    Write-Status "$($errors.Count) device(s) failed sync — check CSV for details" -Status "WARN"
} else {
    Write-Status "All $($results.Count) sync request(s) submitted successfully" -Status "OK"
}

Write-Status "NOTE: Sync takes 5-15 min to appear in Intune portal. Verify via:" -Status "INFO"
Write-Status "  Intune > Devices > [device] > Device sync status" -Status "INFO"
