<#
.SYNOPSIS
    Audits Intune Endpoint Security Baseline assignment status and flags Error/Conflict devices via Graph.

.DESCRIPTION
    Queries Microsoft Graph for all assigned Security Baseline intents (deviceManagement/intents) and
    their per-device assignment/compliance state, then reports which devices are in "Error" or
    "Conflict" for a given baseline versus "Succeeded". This automates the Graph portion of
    Intune/Troubleshooting/Security-Baselines-B.md (Triage step 1, Diagnosis Step 5) so an engineer can
    see baseline drift across the fleet instead of opening each device individually in the portal.

    This script does NOT set MDMWinsOverGP, does NOT modify baseline profiles or assignments, and does
    NOT touch any device settings. It is read-only reporting to support the "Common Fix Paths" in
    Security-Baselines-B.md — the fixes themselves must still be applied manually or via a separate
    remediation script.

.PARAMETER BaselineName
    Optional filter — only report on baseline profiles whose display name matches this wildcard
    pattern (e.g. "*Windows 11*"). Default: all assigned baseline intents.

.PARAMETER IncludeSucceeded
    Switch. If set, includes devices in "Succeeded" state in the console table (they're always
    included in the CSV regardless, for a complete audit trail).

.PARAMETER OutputPath
    Path for CSV export. Defaults to .\SecurityBaselineDrift_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-SecurityBaselineDrift.ps1

.EXAMPLE
    .\Get-SecurityBaselineDrift.ps1 -BaselineName "*Windows 11*" -IncludeSucceeded

.NOTES
    Requires: Microsoft.Graph.Authentication module (uses Invoke-MgGraphRequest against the beta endpoint,
    since deviceManagement/intents is beta-only as of this writing)
    Requires Graph scope: DeviceManagementConfiguration.Read.All
    Run-as: Any account with the above Graph permission.
    Safe: Yes — fully read-only against Microsoft Graph.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BaselineName = "*",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSucceeded,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\SecurityBaselineDrift_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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
# DETECT — find assigned baseline intents
# ---------------------------------------------------------------------------
Write-Status "Retrieving Security Baseline intents..."
try {
    $intents = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/intents").value
}
catch {
    Write-Status "Failed to query deviceManagement/intents: $($_.Exception.Message)" "ERROR"
    throw
}

# Baseline intents carry a templateId referencing a securityBaseline template category.
# Filter to assigned intents matching the name pattern; templateId filtering for "baseline-only"
# is not reliably queryable client-side, so we rely on displayName + isAssigned.
$baselines = $intents | Where-Object { $_.isAssigned -eq $true -and $_.displayName -like $BaselineName }

if (-not $baselines -or $baselines.Count -eq 0) {
    Write-Status "No assigned baseline intents matched pattern '$BaselineName'. Exiting." "WARN"
    return
}
Write-Status "Found $($baselines.Count) assigned baseline profile(s): $($baselines.displayName -join ', ')" "OK"

# ---------------------------------------------------------------------------
# EXECUTE — per-baseline device run states
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($baseline in $baselines) {
    Write-Status "Checking device states for baseline: $($baseline.displayName)..."

    try {
        $deviceStatesUri = "https://graph.microsoft.com/beta/deviceManagement/intents/$($baseline.id)/deviceStates"
        $deviceStates = (Invoke-MgGraphRequest -Method GET -Uri $deviceStatesUri).value
    }
    catch {
        Write-Status "  Could not retrieve device states for '$($baseline.displayName)': $($_.Exception.Message)" "WARN"
        continue
    }

    if (-not $deviceStates -or $deviceStates.Count -eq 0) {
        Write-Status "  No device states reported yet for this baseline (may not have synced)." "WARN"
        continue
    }

    foreach ($ds in $deviceStates) {
        $state = $ds.state
        $flag = switch ($state) {
            "succeeded"     { "OK" }
            "error"         { "ERROR — see Fix 1 (force re-sync) then MDMDiagReport" }
            "conflict"      { "CONFLICT — check MDMWinsOverGP / GPO overlap (Fix 2)" }
            "notApplicable" { "Not applicable to this device (OS/SKU mismatch)" }
            "pending"       { "PENDING — check assignment scope (Fix 4) if stuck >30min" }
            default         { "Unknown state: $state" }
        }

        $results.Add([PSCustomObject]@{
            BaselineName    = $baseline.displayName
            BaselineId      = $baseline.id
            DeviceId        = $ds.deviceId
            DeviceName      = $ds.deviceDisplayName
            UserPrincipal   = $ds.userPrincipalName
            State           = $state
            LastReportedDateTime = $ds.lastReportedDateTime
            Flag            = $flag
        })
    }
}

if ($results.Count -eq 0) {
    Write-Status "No device state rows collected across any baseline. Nothing to report." "WARN"
    return
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
$errors    = @($results | Where-Object { $_.State -eq "error" })
$conflicts = @($results | Where-Object { $_.State -eq "conflict" })
$pending   = @($results | Where-Object { $_.State -eq "pending" })
$succeeded = @($results | Where-Object { $_.State -eq "succeeded" })

Write-Host ""
Write-Status "===== SECURITY BASELINE DRIFT SUMMARY =====" "OK"
Write-Status "Total device-baseline rows:  $($results.Count)"
Write-Status "Succeeded:                   $($succeeded.Count)" "OK"
Write-Status "Error:                       $($errors.Count)" $(if ($errors.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Conflict:                    $($conflicts.Count)" $(if ($conflicts.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Pending:                     $($pending.Count)" $(if ($pending.Count -gt 0) { "WARN" } else { "OK" })

$toShow = if ($IncludeSucceeded) { $results } else { $results | Where-Object { $_.State -ne "succeeded" } }
if ($toShow.Count -gt 0) {
    Write-Host ""
    $toShow | Format-Table BaselineName, DeviceName, State, Flag -AutoSize
}
else {
    Write-Status "No drift detected — every device-baseline pair reports 'Succeeded'." "OK"
}

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full report (including Succeeded rows) exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
