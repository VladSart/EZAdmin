<#
.SYNOPSIS
    Read-only readiness/context audit for the Microsoft Purview DLP SLA Alert Reporting
    Dashboard (Microsoft 365 Roadmap ID 568372, Preview Aug 2026 / GA Sept 2026).

.DESCRIPTION
    The SLA dashboard itself has no documented PowerShell or Microsoft Graph read API as of
    this writing — it is a Purview-portal-only reporting surface (Data Loss Prevention >
    Alerts > SLA dashboard). This script does NOT read, create, or modify dashboard
    configuration or custom SLA thresholds.

    Instead it computes PROXY MTTA/MTTR-style timing metrics directly from raw
    Get-ProtectionAlert records, so an engineer has an independent baseline to compare
    against the portal dashboard's own reported figures. The exact calculation boundaries
    used by the real dashboard are not officially published (see the companion
    DLPSLADashboard-A.md runbook's source-confidence note) — this script's math is a
    reasoned approximation using CreatedTime/LastUpdatedTime/Status, not a guaranteed match
    to Microsoft's own methodology.

    Also audits:
      - RBAC membership for dashboard-visibility roles (DLP Compliance Management /
        View-Only DLP Compliance Management)
      - Tenant licensing signal for aggregate/threshold alert eligibility
      - Alert volume by severity, as a baseline for setting custom SLA thresholds

.PARAMETER OutputPath
    Directory to write CSV exports to. Defaults to the current directory.

.PARAMETER LookbackDays
    Number of days of DLP alert history to pull. Defaults to 30.

.EXAMPLE
    .\Get-DLPSLADashboardReadiness.ps1 -OutputPath C:\Audits -LookbackDays 30

.NOTES
    Requires: Connect-IPPSSession (Security & Compliance PowerShell) and Microsoft.Graph
    (Get-MgSubscribedSku) to be connected before running.
    Safe/read-only: issues no writes, sets no thresholds, resolves no alerts.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [int]$LookbackDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Starting DLP SLA Dashboard readiness/proxy-metrics audit (lookback: $LookbackDays days)" "INFO"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
try {
    $null = Get-ProtectionAlert -ErrorAction Stop
    Write-Status "Security & Compliance PowerShell session detected" "OK"
} catch {
    Write-Status "Not connected to Security & Compliance PowerShell. Run Connect-IPPSSession first. Aborting." "ERROR"
    return
}

$graphConnected = $false
try {
    if ($null -ne (Get-MgContext -ErrorAction Stop)) { $graphConnected = $true }
} catch { }

# ---------------------------------------------------------------------------
# 2. Pull DLP alerts for the lookback window
# ---------------------------------------------------------------------------
$alerts = Get-ProtectionAlert | Where-Object {
    $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddDays(-$LookbackDays)
}

if (-not $alerts -or $alerts.Count -eq 0) {
    Write-Status "No DLP alerts found in the last $LookbackDays day(s). A live dashboard would show sparse/no data for this tenant right now — this is expected, not a defect." "WARN"
} else {
    Write-Status "Found $($alerts.Count) DLP alert(s) in the last $LookbackDays day(s)" "OK"
}

# ---------------------------------------------------------------------------
# 3. Compute proxy timing metrics (CAVEAT: approximation, not Microsoft's own definition)
# ---------------------------------------------------------------------------
$proxyMetrics = foreach ($a in $alerts) {
    $ageHours = if ($a.CreatedTime) { [math]::Round(((Get-Date) - $a.CreatedTime).TotalHours, 2) } else { $null }
    $resolveHours = if ($a.CreatedTime -and $a.Status -eq "Resolved") {
        [math]::Round(($a.LastUpdatedTime - $a.CreatedTime).TotalHours, 2)
    } else { $null }
    [pscustomobject]@{
        Name           = $a.Name
        Severity       = $a.Severity
        Status         = $a.Status
        CreatedTime    = $a.CreatedTime
        LastUpdatedTime = $a.LastUpdatedTime
        AgeHours       = $ageHours
        ProxyResolveHours = $resolveHours
    }
}
$proxyMetrics | Export-Csv (Join-Path $OutputPath "DlpAlertProxyMetrics.csv") -NoTypeInformation

$bySeverity = $proxyMetrics | Group-Object Severity | ForEach-Object {
    $resolved = $_.Group | Where-Object { $null -ne $_.ProxyResolveHours }
    [pscustomobject]@{
        Severity            = $_.Name
        AlertCount          = $_.Count
        ResolvedCount       = $resolved.Count
        AvgProxyResolveHours = if ($resolved) { [math]::Round(($resolved.ProxyResolveHours | Measure-Object -Average).Average, 2) } else { $null }
    }
}
$bySeverity | Export-Csv (Join-Path $OutputPath "ProxyMetricsBySeverity.csv") -NoTypeInformation

Write-Host ""
Write-Host "=== Proxy MTTR-style summary by severity (approximation only — see script header) ===" -ForegroundColor Cyan
$bySeverity | Format-Table -AutoSize

# ---------------------------------------------------------------------------
# 4. RBAC — dashboard visibility roles
# ---------------------------------------------------------------------------
try {
    $fullRole = Get-RoleGroupMember -Identity "DLP Compliance Management" -ErrorAction Stop
    $fullRole | Select-Object Name, RecipientType | Export-Csv (Join-Path $OutputPath "DlpComplianceManagementMembers.csv") -NoTypeInformation
    Write-Status "DLP Compliance Management: $($fullRole.Count) member(s)" "OK"
} catch {
    Write-Status "Could not read DLP Compliance Management role membership: $($_.Exception.Message)" "WARN"
}

try {
    $viewOnlyRole = Get-RoleGroupMember -Identity "View-Only DLP Compliance Management" -ErrorAction Stop
    $viewOnlyRole | Select-Object Name, RecipientType | Export-Csv (Join-Path $OutputPath "ViewOnlyDlpComplianceManagementMembers.csv") -NoTypeInformation
    Write-Status "View-Only DLP Compliance Management: $($viewOnlyRole.Count) member(s)" "OK"
} catch {
    Write-Status "Could not read View-Only DLP Compliance Management role membership: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------------------------
# 5. Licensing signal for aggregate/threshold alert eligibility
# ---------------------------------------------------------------------------
if ($graphConnected) {
    try {
        $skus = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "SPE_E5|ENTERPRISEPREMIUM|IDENTITY_THREAT_PROTECTION|M365_E5_SUITE_COMPONENTS" } |
            Select-Object SkuPartNumber, PrepaidUnits, ConsumedUnits
        $skus | Export-Csv (Join-Path $OutputPath "AggregateAlertLicensingSignal.csv") -NoTypeInformation
        if ($skus) {
            Write-Status "Found $($skus.Count) SKU(s) consistent with aggregate/threshold alert eligibility" "OK"
        } else {
            Write-Status "No SKUs found consistent with aggregate/threshold alert eligibility — tenant may be limited to single-event alerts only" "WARN"
        }
    } catch {
        Write-Status "Graph SKU query failed: $($_.Exception.Message)" "WARN"
    }
} else {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph first for the licensing signal check." "WARN"
}

# ---------------------------------------------------------------------------
# 6. Portal-only checklist
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Portal-only items this script CANNOT check ===" -ForegroundColor Yellow
Write-Host "  [ ] Whether the tenant has received the Roadmap 568372 Preview/GA rollout"
Write-Host "  [ ] Actual dashboard-reported MTTA/MTTD/MTTR values (compare manually against ProxyMetricsBySeverity.csv)"
Write-Host "  [ ] Configured custom SLA thresholds per severity"
Write-Host "  [ ] Top Sensitive Information Types (SITs) exposed view"
Write-Host "  Verify all four at: Purview portal > Data loss prevention > Alerts > SLA dashboard"
Write-Host ""
Write-Status "Audit complete. CSV exports written to $OutputPath" "OK"
