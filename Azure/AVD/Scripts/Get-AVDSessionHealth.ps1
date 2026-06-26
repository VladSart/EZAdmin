<#
.SYNOPSIS
    Reports Azure Virtual Desktop session host health, active sessions, drain mode status, and FSLogix VHD availability.

.DESCRIPTION
    Connects to Azure and queries one or more AVD host pools to produce a health dashboard.
    Reports include:
      - Session host availability and status
      - Active user sessions per host
      - Drain mode (maintenance) status
      - RD Agent version per host
      - FSLogix profile VHD share connectivity (from the management machine, not the session hosts)
      - Host pool load balancing algorithm and session limits

    Does NOT require running on a session host — runs from any Windows machine with Az module and appropriate permissions.

.PARAMETER ResourceGroupName
    Resource group containing the host pool(s). If omitted, scans all host pools in the subscription.

.PARAMETER HostPoolName
    Name of a specific host pool to query. If omitted, queries all host pools in the resource group.

.PARAMETER SubscriptionId
    Azure subscription ID. If omitted, uses the current Az context subscription.

.PARAMETER FSLogixSharePath
    UNC path to the FSLogix profile share (e.g. \\storage.file.core.windows.net\profiles).
    If provided, tests SMB connectivity and lists VHD(x) files.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\AVDHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-AVDSessionHealth.ps1 -ResourceGroupName 'rg-avd-prod' -HostPoolName 'hp-general'

.EXAMPLE
    .\Get-AVDSessionHealth.ps1 -ResourceGroupName 'rg-avd-prod' `
        -FSLogixSharePath '\\stcontosoavd.file.core.windows.net\profiles' `
        -ExportPath 'C:\Reports\AVDHealth.csv'

.NOTES
    Requires: Az.DesktopVirtualization, Az.Accounts modules
    Install:  Install-Module Az.DesktopVirtualization, Az.Accounts -Scope CurrentUser
    Permissions: Desktop Virtualization Reader (or higher) on host pool resource group
    Safe to run: Read-only. No session hosts are modified.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$HostPoolName,
    [string]$SubscriptionId,
    [string]$FSLogixSharePath,
    [string]$ExportPath = "C:\Temp\AVDHealth_$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

#region — Preflight
Write-Status "Azure Virtual Desktop Session Health Reporter" "INFO"
Write-Status "=============================================" "INFO"

# Ensure Az modules are available
$requiredModules = @('Az.Accounts', 'Az.DesktopVirtualization')
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        throw "Missing required module: $mod"
    }
}

# Connect / set subscription
try {
    $ctx = Get-AzContext
    if (-not $ctx) {
        Write-Status "No Azure context — launching interactive login..." "WARN"
        Connect-AzAccount
        $ctx = Get-AzContext
    }
    Write-Status "Azure context: $($ctx.Account.Id) | $($ctx.Subscription.Name)" "OK"
} catch {
    Write-Status "Failed to get Azure context: $_" "ERROR"
    throw
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Status "Switched to subscription: $SubscriptionId" "OK"
}

# Ensure output directory exists
$outDir = Split-Path $ExportPath -Parent
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
#endregion

#region — Discover host pools
Write-Status "Discovering host pools..." "INFO"

$hostPoolParams = @{}
if ($ResourceGroupName) { $hostPoolParams['ResourceGroupName'] = $ResourceGroupName }
if ($HostPoolName)       { $hostPoolParams['Name']              = $HostPoolName       }

try {
    if ($ResourceGroupName -and $HostPoolName) {
        $hostPools = @(Get-AzWvdHostPool @hostPoolParams)
    } elseif ($ResourceGroupName) {
        $hostPools = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName
    } else {
        # Get all host pools across all resource groups in subscription
        $hostPools = Get-AzWvdHostPool
    }
} catch {
    Write-Status "Failed to retrieve host pools: $_" "ERROR"
    throw
}

if (-not $hostPools -or $hostPools.Count -eq 0) {
    Write-Status "No host pools found with the specified parameters." "WARN"
    return
}

Write-Status "Found $($hostPools.Count) host pool(s)." "OK"
#endregion

#region — Session host health
$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($pool in $hostPools) {
    # Parse resource group from pool ID if not provided
    $poolRG = ($pool.Id -split '/')[4]
    $poolName = $pool.Name

    Write-Status "Querying host pool: $poolName (RG: $poolRG)" "INFO"

    # Host pool metadata
    $loadBalancingAlgo = $pool.LoadBalancerType
    $maxSessionLimit   = $pool.MaxSessionLimit

    try {
        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $poolRG -HostPoolName $poolName
    } catch {
        Write-Status "  Could not retrieve session hosts for $poolName`: $_" "WARN"
        continue
    }

    if (-not $sessionHosts) {
        Write-Status "  No session hosts found in $poolName." "WARN"
        continue
    }

    foreach ($host in $sessionHosts) {
        $hostShortName = $host.Name.Split('/')[-1]

        # Active sessions for this host
        try {
            $sessions = @(Get-AzWvdUserSession -ResourceGroupName $poolRG `
                -HostPoolName $poolName -SessionHostName $hostShortName -ErrorAction SilentlyContinue)
            $sessionCount = $sessions.Count
            $activeUsers  = ($sessions | Where-Object { $_.SessionState -eq 'Active' }).Count
            $disconnected = ($sessions | Where-Object { $_.SessionState -eq 'Disconnected' }).Count
        } catch {
            $sessionCount = -1; $activeUsers = -1; $disconnected = -1
        }

        # Health status interpretation
        $healthStatus = $host.Status
        $healthIcon   = switch ($healthStatus) {
            'Available'     { '✅' }
            'Unavailable'   { '❌' }
            'NeedsAssistance' { '⚠️' }
            'NoHeartbeat'   { '🔴' }
            'NotJoinedToDomain' { '🔴' }
            'Shutdown'      { '⏹️' }
            default         { '❓' }
        }

        $entry = [PSCustomObject]@{
            HostPool            = $poolName
            ResourceGroup       = $poolRG
            SessionHost         = $hostShortName
            HealthStatus        = "$healthIcon $healthStatus"
            DrainMode           = if ($host.AllowNewSession -eq $false) { '🔧 DRAIN MODE ON' } else { 'Normal' }
            ActiveSessions      = $activeUsers
            DisconnectedSessions = $disconnected
            TotalSessions       = $sessionCount
            MaxSessions         = $maxSessionLimit
            LoadBalancing       = $loadBalancingAlgo
            AgentVersion        = $host.AgentVersion
            LastHeartbeat       = $host.LastHeartBeat
            VirtualMachineId    = $host.ResourceId
            OSVersion           = $host.OsVersion
        }

        $report.Add($entry)

        # Console status line
        $drainTag = if ($host.AllowNewSession -eq $false) { ' [DRAIN]' } else { '' }
        Write-Host "  $healthIcon $hostShortName$drainTag | Sessions: $activeUsers active, $disconnected disconnected | Agent: $($host.AgentVersion)"
    }
}
#endregion

#region — FSLogix share connectivity check
if ($FSLogixSharePath) {
    Write-Status "Checking FSLogix share connectivity: $FSLogixSharePath" "INFO"
    try {
        if (Test-Path $FSLogixSharePath) {
            Write-Status "Share reachable: $FSLogixSharePath" "OK"
            $vhds = Get-ChildItem -Path $FSLogixSharePath -Filter '*.vhd*' -Recurse -ErrorAction SilentlyContinue
            Write-Status "VHD(x) files found: $($vhds.Count)" "OK"
            if ($vhds.Count -gt 0) {
                $vhds | Select-Object Name, @{N='SizeMB';E={[math]::Round($_.Length/1MB,1)}}, LastWriteTime |
                    Format-Table -AutoSize
            }
        } else {
            Write-Status "Share NOT reachable: $FSLogixSharePath" "ERROR"
            Write-Status "Check SMB connectivity, DNS, and Azure Files authentication." "WARN"
        }
    } catch {
        Write-Status "FSLogix share check failed: $_" "WARN"
    }
}
#endregion

#region — Export and summary
Write-Status "" "INFO"
Write-Status "=== SUMMARY ===" "INFO"

$totalHosts     = $report.Count
$availableHosts = ($report | Where-Object { $_.HealthStatus -match 'Available' }).Count
$drainHosts     = ($report | Where-Object { $_.DrainMode -match 'DRAIN' }).Count
$totalSessions  = ($report | Where-Object { $_.TotalSessions -ge 0 } |
    Measure-Object -Property TotalSessions -Sum).Sum

Write-Status "Total session hosts : $totalHosts" "INFO"
Write-Status "Available           : $availableHosts" $(if ($availableHosts -eq $totalHosts) {'OK'} else {'WARN'})
Write-Status "In drain mode       : $drainHosts" "INFO"
Write-Status "Total active sessions: $totalSessions" "INFO"

# Hosts needing attention
$attention = $report | Where-Object { $_.HealthStatus -notmatch 'Available' -and $_.DrainMode -notmatch 'DRAIN' }
if ($attention) {
    Write-Status "Hosts needing attention:" "WARN"
    $attention | Select-Object SessionHost, HealthStatus, LastHeartbeat | Format-Table -AutoSize
}

# Export CSV
$report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" "OK"
#endregion
