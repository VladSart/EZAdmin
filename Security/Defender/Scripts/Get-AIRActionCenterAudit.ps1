<#
.SYNOPSIS
    Audits Microsoft Defender for Endpoint Automated Investigation & Response (AIR)
    activity via Microsoft Graph Security API — pending approval queue age, recent
    remediation actions, and alert-to-action correlation for escalation packaging.

.DESCRIPTION
    Read-only audit against Microsoft Graph. Reports:
      - Recent security alerts (alerts_v2) with determination/status, to correlate
        against Action Center activity
      - Flags alerts older than -PendingApprovalWarningDays with a status suggesting
        an unresolved/pending state, as a proxy warning for the Action Center
        7-day pending-action expiry window (Action Center Pending-queue state itself
        is portal-managed and has no stable, documented Graph read endpoint as of
        this writing — this script surfaces the closest available Graph signal and
        should be paired with a manual Action Center review, not used as the sole
        source of truth)
      - Does NOT approve, reject, or undo any action — audit/reporting only

.PARAMETER PendingApprovalWarningDays
    Age threshold (in days) at which an unresolved alert is flagged as approaching
    the Action Center's 7-day pending-action auto-reject window. Default: 5 (gives
    a 2-day buffer before the actual 7-day expiry).

.PARAMETER TopAlerts
    Number of most recent alerts to pull. Default: 100.

.PARAMETER OutputPath
    Folder to write the CSV export to. Default: current directory.

.EXAMPLE
    .\Get-AIRActionCenterAudit.ps1
    Pulls the most recent 100 alerts and flags any unresolved ones older than 5 days.

.EXAMPLE
    .\Get-AIRActionCenterAudit.ps1 -PendingApprovalWarningDays 6 -TopAlerts 250 -OutputPath C:\Evidence

.NOTES
    Requires: Microsoft.Graph PowerShell SDK, an app registration or delegated
    session with SecurityEvents.Read.All (and SecurityActions.Read.All if available)
    Graph permissions.
    Run-as: any account/app with the above Graph scopes consented.
    Safe/unsafe: fully read-only against Graph. Safe to run at any time.
    Known limitation: per-device-group automation-level configuration is portal-only
    (Settings > Endpoints > Device groups) with no stable Graph endpoint documented
    for this specific setting as of this writing — pair this script's output with a
    manual export/screenshot of that page for a complete evidence pack.
#>

[CmdletBinding()]
param(
    [int]$PendingApprovalWarningDays = 5,
    [int]$TopAlerts = 100,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph PowerShell SDK not found. Install-Module Microsoft.Graph -Scope CurrentUser" "ERROR"
    throw "Microsoft.Graph module missing"
}

if (-not (Test-Path $OutputPath)) {
    Write-Status "OutputPath '$OutputPath' does not exist, creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "No active Graph session — connecting with required scopes..."
        Connect-MgGraph -Scopes "SecurityEvents.Read.All" -NoWelcome
    } else {
        Write-Status "Using existing Graph session for $($context.Account)"
    }
} catch {
    Write-Status "Failed to establish Graph session: $($_.Exception.Message)" "ERROR"
    throw
}

# ---------- Detect / Execute ----------
Write-Status "Pulling the $TopAlerts most recent security alerts from Microsoft Graph..."
try {
    $uri = "https://graph.microsoft.com/v1.0/security/alerts_v2?`$top=$TopAlerts&`$orderby=createdDateTime desc"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    $alerts = $response.value
} catch {
    Write-Status "Graph request failed: $($_.Exception.Message)" "ERROR"
    throw
}

Write-Status "Retrieved $($alerts.Count) alert(s)."

$unresolvedStatuses = @('new', 'inProgress')
$warnThreshold = (Get-Date).AddDays(-$PendingApprovalWarningDays)

$flagged = $alerts | Where-Object {
    $_.status -in $unresolvedStatuses -and
    [datetime]$_.createdDateTime -lt $warnThreshold
}

if ($flagged) {
    Write-Status "$($flagged.Count) alert(s) unresolved and older than $PendingApprovalWarningDays days — approaching the Action Center's 7-day pending-action auto-reject window. Verify in the portal Pending tab." "WARN"
} else {
    Write-Status "No alerts found unresolved beyond the $PendingApprovalWarningDays-day warning threshold." "OK"
}

# ---------- Report ----------
$alertExport = $alerts | Select-Object id, title, severity, status, determination,
    classification, serviceSource, createdDateTime,
    @{n = 'AgeDays'; e = { [math]::Round(((Get-Date) - [datetime]$_.createdDateTime).TotalDays, 1) } },
    @{n = 'ApproachingPendingExpiry'; e = { ($_.status -in $unresolvedStatuses) -and ([datetime]$_.createdDateTime -lt $warnThreshold) } }

$exportPath = Join-Path $OutputPath "AIR-AlertAudit.csv"
$alertExport | Export-Csv -Path $exportPath -NoTypeInformation
Write-Status "Full alert export written to $exportPath" "OK"

if ($flagged) {
    $flaggedPath = Join-Path $OutputPath "AIR-FlaggedApproachingExpiry.csv"
    $alertExport | Where-Object ApproachingPendingExpiry | Export-Csv -Path $flaggedPath -NoTypeInformation
    Write-Status "Flagged (approaching-expiry) subset written to $flaggedPath" "WARN"
}

Write-Status "REMINDER: device-group automation-level configuration is portal-only (Settings > Endpoints > Device groups) — capture that page manually to complete an evidence pack alongside this export." "WARN"

$alertExport | Select-Object -First 20 | Format-Table -AutoSize
