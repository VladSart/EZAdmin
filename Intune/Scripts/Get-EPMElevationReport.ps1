<#
.SYNOPSIS
    Audits Endpoint Privilege Management (EPM) agent health and elevation rule delivery via Graph and local device state.

.DESCRIPTION
    Combines a local device-side check (LsmsService status, EPM policy files, IME log signal) with a
    Graph-side check of assigned Elevation Settings and Elevation Rules policies and their per-device
    deployment state. Automates the Graph + local diagnostic steps in Intune/Troubleshooting/EPM-B.md
    (Triage steps 1-4) so an engineer can confirm licence, policy delivery, and agent health without
    working through each step manually on every device.

    This script does NOT modify EPM policies, does NOT reassign licences, and does NOT restart services.
    It is read-only reporting to support the "Common Fix Paths" in EPM-B.md — remediation must still be
    applied manually or via a separate script.

.PARAMETER DeviceName
    Optional filter — only report Graph-side policy state for devices whose display name matches this
    wildcard pattern (e.g. "LT-FIN-*"). Default: all devices with an EPM policy assignment.

.PARAMETER SkipLocalCheck
    Switch. Skip the local device-side checks (service, policy files, IME log). Use when running
    remotely against Graph only, e.g. from an admin workstation not enrolled in Intune.

.PARAMETER OutputPath
    Path for CSV export of the Graph-side per-device policy state. Defaults to
    .\EPMElevationReport_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-EPMElevationReport.ps1

.EXAMPLE
    .\Get-EPMElevationReport.ps1 -DeviceName "LT-FIN-*" -SkipLocalCheck

.NOTES
    Requires: Microsoft.Graph.Authentication module (uses Invoke-MgGraphRequest against the beta
    endpoint for deviceManagement/intents, which covers EPM Elevation Settings/Rules policies).
    Requires Graph scope: DeviceManagementConfiguration.Read.All
    Requires an Intune Suite or standalone EPM licence to be assigned for policy states to populate.
    Run-as (local check portion): local administrator on the target device, or run via IME/RMM as SYSTEM.
    Safe: Yes — fully read-only against Microsoft Graph and local device state.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeviceName = "*",

    [Parameter(Mandatory = $false)]
    [switch]$SkipLocalCheck,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\EPMElevationReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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
    Write-Status "===== LOCAL EPM AGENT CHECK =====" "OK"

    $svc = Get-Service -Name "LsmsService" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Status "LsmsService (EPM agent) not found on this device — EPM agent not installed / not yet delivered." "ERROR"
    }
    elseif ($svc.Status -ne "Running") {
        Write-Status "LsmsService found but Status = $($svc.Status). See Fix 1 — Repair EPM agent." "WARN"
    }
    else {
        Write-Status "LsmsService is Running." "OK"
    }

    $epmPolicyPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Policies\ElevationControl"
    if (Test-Path $epmPolicyPath) {
        $files = Get-ChildItem $epmPolicyPath -ErrorAction SilentlyContinue
        if ($files) {
            Write-Status "EPM policy files present ($($files.Count)) — last write: $(($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime)" "OK"
        }
        else {
            Write-Status "EPM policy folder exists but is empty — no policy delivered yet. See Fix 2 — Force Intune sync." "WARN"
        }
    }
    else {
        Write-Status "EPM policy folder not found — device has not received any elevation policy. See Fix 2 — Force Intune sync." "WARN"
    }

    $imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    if (Test-Path $imeLog) {
        $matches = Select-String -Path $imeLog -Pattern "ElevationControl|EPM|LsmsService" -ErrorAction SilentlyContinue |
            Select-Object -Last 5
        if ($matches) {
            Write-Status "Last 5 EPM-related IME log lines:" "INFO"
            $matches | ForEach-Object { Write-Host "  $($_.Line)" }
        }
        else {
            Write-Status "No EPM-related entries found in IME log — policy may not have been targeted at this device yet." "WARN"
        }
    }
    else {
        Write-Status "IME log not found at expected path — IntuneManagementExtension may not be installed." "WARN"
    }

    $epmAgentLog = "C:\ProgramData\Microsoft\EPM\Logs\Microsoft.Management.Elevation.Agent.log"
    if (Test-Path $epmAgentLog) {
        Write-Status "EPM agent log found. Last 10 lines:" "INFO"
        Get-Content $epmAgentLog -Tail 10 | ForEach-Object { Write-Host "  $_" }
    }

    Write-Host ""
}
else {
    Write-Status "Skipping local device-side check (-SkipLocalCheck specified)." "INFO"
}

# ---------------------------------------------------------------------------
# PREFLIGHT — GRAPH
# ---------------------------------------------------------------------------
Write-Status "===== GRAPH-SIDE EPM POLICY CHECK =====" "OK"
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
# DETECT — check licence and locate EPM intents
# ---------------------------------------------------------------------------
Write-Status "Checking for Intune Suite / EPM licence in tenant..."
try {
    $skus = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/subscribedSkus").value
    $epmSku = $skus | Where-Object { $_.skuPartNumber -match "INTUNE_SUITE|EPM" }
    if ($epmSku) {
        Write-Status "EPM-eligible licence found: $($epmSku.skuPartNumber -join ', ')" "OK"
    }
    else {
        Write-Status "No INTUNE_SUITE or EPM SKU found in tenant. EPM policies will not enforce without a licence. See Fix 4 — Assign licence." "ERROR"
    }
}
catch {
    Write-Status "Could not query subscribedSkus: $($_.Exception.Message)" "WARN"
}

Write-Status "Retrieving EPM (Elevation Settings / Elevation Rules) intents..."
try {
    $intents = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/intents").value
}
catch {
    Write-Status "Failed to query deviceManagement/intents: $($_.Exception.Message)" "ERROR"
    throw
}

$epmIntents = $intents | Where-Object { $_.displayName -match "Elevation" -and $_.isAssigned -eq $true }

if (-not $epmIntents -or $epmIntents.Count -eq 0) {
    Write-Status "No assigned EPM Elevation Settings/Rules intents found. Confirm policies exist and are assigned in Intune > Endpoint Security > Endpoint Privilege Management." "WARN"
    return
}
Write-Status "Found $($epmIntents.Count) assigned EPM policy(ies): $($epmIntents.displayName -join ', ')" "OK"

# ---------------------------------------------------------------------------
# EXECUTE — per-policy device deployment states
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($intent in $epmIntents) {
    Write-Status "Checking device states for policy: $($intent.displayName)..."
    try {
        $deviceStatesUri = "https://graph.microsoft.com/beta/deviceManagement/intents/$($intent.id)/deviceStates"
        $deviceStates = (Invoke-MgGraphRequest -Method GET -Uri $deviceStatesUri).value
    }
    catch {
        Write-Status "  Could not retrieve device states for '$($intent.displayName)': $($_.Exception.Message)" "WARN"
        continue
    }

    if (-not $deviceStates -or $deviceStates.Count -eq 0) {
        Write-Status "  No device states reported yet for this policy (may not have synced)." "WARN"
        continue
    }

    foreach ($ds in $deviceStates) {
        if ($DeviceName -ne "*" -and $ds.deviceDisplayName -notlike $DeviceName) { continue }

        $flag = switch ($ds.state) {
            "succeeded" { "OK" }
            "error"     { "ERROR — check licence assignment and re-sync (Fix 2/4)" }
            "conflict"  { "CONFLICT — check for overlapping elevation rule scope" }
            "pending"   { "PENDING — check group assignment and Intune sync timing" }
            default     { "Unknown state: $($ds.state)" }
        }

        $results.Add([PSCustomObject]@{
            PolicyName    = $intent.displayName
            PolicyId      = $intent.id
            DeviceName    = $ds.deviceDisplayName
            UserPrincipal = $ds.userPrincipalName
            State         = $ds.state
            LastReported  = $ds.lastReportedDateTime
            Flag          = $flag
        })
    }
}

# ---------------------------------------------------------------------------
# VALIDATE / REPORT
# ---------------------------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Status "No device state rows matched the given filter. Nothing to report." "WARN"
    return
}

$errors    = @($results | Where-Object { $_.State -eq "error" })
$conflicts = @($results | Where-Object { $_.State -eq "conflict" })
$pending   = @($results | Where-Object { $_.State -eq "pending" })
$succeeded = @($results | Where-Object { $_.State -eq "succeeded" })

Write-Host ""
Write-Status "===== EPM ELEVATION POLICY SUMMARY =====" "OK"
Write-Status "Total device-policy rows: $($results.Count)"
Write-Status "Succeeded:  $($succeeded.Count)" "OK"
Write-Status "Error:      $($errors.Count)" $(if ($errors.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Conflict:   $($conflicts.Count)" $(if ($conflicts.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Pending:    $($pending.Count)" $(if ($pending.Count -gt 0) { "WARN" } else { "OK" })

$results | Where-Object { $_.State -ne "succeeded" } | Format-Table PolicyName, DeviceName, State, Flag -AutoSize

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Full report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
}

Write-Status "Done." "OK"
