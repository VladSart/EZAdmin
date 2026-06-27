<#
.SYNOPSIS
    Retrieves and reports Power Automate flow run history for one or all flows in an environment.

.DESCRIPTION
    Queries the Power Platform Management API to retrieve flow run history, including:
    - Run status (Succeeded, Failed, Cancelled, Running)
    - Start time, end time, and duration
    - Error codes and messages for failed runs
    - Trigger type (manual, scheduled, automated)

    Useful for:
    - Troubleshooting repeated flow failures
    - Auditing flow execution over a time period
    - Identifying throttled or long-running flows
    - Generating a compliance evidence pack

    Outputs results to console and exports to CSV.

    Requires the Power Platform tenant admin role or Environment Admin role in the target environment.

.PARAMETER EnvironmentName
    The Power Platform environment name (GUID). Retrieve via Get-AdminPowerAppEnvironment.
    Example: "Default-a1b2c3d4-0000-0000-0000-000000000000"

.PARAMETER FlowId
    Optional. The GUID of a specific flow to query. If omitted, queries all flows in the environment.

.PARAMETER FlowDisplayName
    Optional. Filter by flow display name (partial match, case-insensitive).

.PARAMETER DaysBack
    Number of days of history to retrieve. Default: 7. Max supported: 28 (API limitation).

.PARAMETER StatusFilter
    Filter runs by status: All, Failed, Succeeded, Cancelled. Default: All.

.PARAMETER OutputPath
    Path to export CSV report. Default: C:\Temp\FlowRunHistory-<timestamp>.csv

.EXAMPLE
    # Get all flow run history for the last 7 days in the default environment
    .\Get-FlowRunHistory.ps1 -EnvironmentName "Default-<tenantId>"

.EXAMPLE
    # Get failed runs only for a specific flow
    .\Get-FlowRunHistory.ps1 -EnvironmentName "Default-<tenantId>" -FlowId "<flowGuid>" -StatusFilter Failed -DaysBack 14

.EXAMPLE
    # Find failures across all flows matching a name pattern
    .\Get-FlowRunHistory.ps1 -EnvironmentName "Default-<tenantId>" -FlowDisplayName "Invoice Approval" -StatusFilter Failed

.NOTES
    Requires: PowerShell 5.1+, Microsoft.PowerApps.Administration.PowerShell module
    Install:  Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
    Auth:     Add-PowerAppsAccount (prompts for credentials)
    Permissions: Power Platform Service Admin, Environment Admin, or Global Admin
    Rate limits: Power Platform Admin APIs are throttled — large environments may slow this script
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter()][string]$FlowId,
    [Parameter()][string]$FlowDisplayName,
    [Parameter()][ValidateRange(1,28)][int]$DaysBack = 7,
    [Parameter()][ValidateSet("All","Failed","Succeeded","Cancelled","Running")][string]$StatusFilter = "All",
    [Parameter()][string]$OutputPath = "C:\Temp\FlowRunHistory-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

function Format-Duration {
    param([datetime]$Start, [datetime]$End)
    $Span = $End - $Start
    if ($Span.TotalMinutes -lt 1) { return "$([int]$Span.TotalSeconds)s" }
    if ($Span.TotalHours -lt 1)   { return "$([int]$Span.TotalMinutes)m $($Span.Seconds)s" }
    return "$([int]$Span.TotalHours)h $($Span.Minutes)m"
}

# ─── Preflight ────────────────────────────────────────────────────────────────

Write-Status "Checking for Microsoft.PowerApps.Administration.PowerShell module..."
if (-not (Get-Module -ListAvailable -Name "Microsoft.PowerApps.Administration.PowerShell")) {
    Write-Status "Module not found. Installing..." "WARN"
    Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop

Write-Status "Authenticating to Power Platform..."
try {
    Add-PowerAppsAccount
} catch {
    Write-Status "Authentication failed: $_" "ERROR"
    exit 1
}

# ─── Collect Flows ────────────────────────────────────────────────────────────

Write-Status "Retrieving flows from environment: $EnvironmentName"

if ($FlowId) {
    try {
        $Flows = @(Get-AdminFlow -FlowName $FlowId -EnvironmentName $EnvironmentName)
    } catch {
        Write-Status "Flow ID $FlowId not found in environment $EnvironmentName" "ERROR"
        exit 1
    }
} else {
    $Flows = Get-AdminFlow -EnvironmentName $EnvironmentName -ErrorAction SilentlyContinue
    if ($FlowDisplayName) {
        $Flows = $Flows | Where-Object { $_.DisplayName -like "*$FlowDisplayName*" }
        Write-Status "Filtered to $($Flows.Count) flows matching: $FlowDisplayName"
    }
}

if (-not $Flows -or $Flows.Count -eq 0) {
    Write-Status "No flows found matching criteria." "WARN"
    exit 0
}

Write-Status "Found $($Flows.Count) flow(s) to query." "OK"

# ─── Collect Run History ──────────────────────────────────────────────────────

$Since = (Get-Date).AddDays(-$DaysBack).ToString("yyyy-MM-ddT00:00:00Z")
$AllRuns = [System.Collections.Generic.List[PSCustomObject]]::new()
$FlowsWithErrors = 0
$TotalRuns = 0

foreach ($Flow in $Flows) {
    $FlowName = $Flow.FlowName
    $DisplayName = $Flow.DisplayName

    Write-Status "Querying runs for: $DisplayName ($FlowName)..."

    try {
        $Runs = Get-AdminFlowRun -FlowName $FlowName -EnvironmentName $EnvironmentName -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $Since }

        if (-not $Runs) {
            Write-Status "  No runs found in last $DaysBack days." "WARN"
            continue
        }

        $FlowHadErrors = $false

        foreach ($Run in $Runs) {
            $Status = $Run.Status
            if ($StatusFilter -ne "All" -and $Status -ne $StatusFilter) { continue }

            $StartTime = [datetime]$Run.StartTime
            $EndTime   = if ($Run.EndTime) { [datetime]$Run.EndTime } else { Get-Date }
            $Duration  = Format-Duration $StartTime $EndTime

            # Extract error info for failed runs
            $ErrorCode = ""
            $ErrorMessage = ""
            if ($Status -eq "Failed" -and $Run.Error) {
                $ErrorCode    = $Run.Error.code
                $ErrorMessage = $Run.Error.message -replace "`n"," " -replace "`r",""
                $FlowHadErrors = $true
            }

            $AllRuns.Add([PSCustomObject]@{
                FlowDisplayName = $DisplayName
                FlowId          = $FlowName
                RunId           = $Run.RunName
                Status          = $Status
                TriggerType     = $Run.TriggerType
                StartTime       = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
                EndTime         = if ($Run.EndTime) { $EndTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Still running" }
                Duration        = $Duration
                ErrorCode       = $ErrorCode
                ErrorMessage    = $ErrorMessage
                Environment     = $EnvironmentName
            })

            $TotalRuns++
        }

        if ($FlowHadErrors) { $FlowsWithErrors++ }

    } catch {
        Write-Status "  Failed to retrieve runs for $DisplayName : $_" "WARN"
    }
}

# ─── Report ───────────────────────────────────────────────────────────────────

Write-Status "`n═══════════════════════════════════════════════" "OK"
Write-Status "FLOW RUN HISTORY SUMMARY" "OK"
Write-Status "Environment  : $EnvironmentName"
Write-Status "Period       : Last $DaysBack days (since $Since)"
Write-Status "Flows queried: $($Flows.Count)"
Write-Status "Total runs   : $TotalRuns"
Write-Status "Status filter: $StatusFilter"

if ($AllRuns.Count -gt 0) {
    Write-Status "`nRun Status Breakdown:"
    $AllRuns | Group-Object Status | Sort-Object Count -Descending | ForEach-Object {
        $StatusColour = switch ($_.Name) {
            "Succeeded" { "Green" }
            "Failed"    { "Red" }
            "Cancelled" { "Yellow" }
            default     { "Cyan" }
        }
        Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor $StatusColour
    }

    if ($FlowsWithErrors -gt 0) {
        Write-Status "`nFlows with failures: $FlowsWithErrors" "WARN"
        Write-Status "`nTop 10 most recent failures:"
        $AllRuns | Where-Object Status -eq "Failed" | Sort-Object StartTime -Descending | Select-Object -First 10 |
            Format-Table FlowDisplayName, StartTime, Duration, ErrorCode, ErrorMessage -AutoSize -Wrap
    }

    # Export
    New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force -ErrorAction SilentlyContinue | Out-Null
    $AllRuns | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Report exported to: $OutputPath" "OK"
} else {
    Write-Status "No runs matched filter: $StatusFilter in last $DaysBack days." "WARN"
}

Write-Status "Done." "OK"
