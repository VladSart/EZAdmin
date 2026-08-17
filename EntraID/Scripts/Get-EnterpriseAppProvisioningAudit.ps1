<#
.SYNOPSIS
    Read-only audit of Microsoft Entra ID Enterprise Application (SCIM) provisioning jobs.

.DESCRIPTION
    Enumerates every Service Principal in the tenant that has a configured synchronization
    (provisioning) job, reports current job status (Active/Paused/Quarantine/NotStarted),
    quarantine reason where applicable, last successful/last execution timestamps, and pulls
    recent failure counts from the provisioning logs grouped by failure reason so the most
    common root cause surfaces without manually paging through the portal UI.

    Does not modify any provisioning configuration, credentials, mappings, or scoping filters.
    Does not restart, pause, or otherwise change job state. Purely a reporting tool intended
    to be run before opening a ticket or attempting any fix in EnterpriseAppProvisioning-B.md.

.PARAMETER AppDisplayName
    Optional. Limit the audit to a single Enterprise Application by its Service Principal
    display name. If omitted, every Service Principal with a provisioning job is audited.

.PARAMETER FailureLookbackDays
    How many days of provisioning log history to scan for failure-reason grouping per app.
    Default: 7.

.PARAMETER OutputPath
    Folder to write the CSV exports to. Default: current directory.

.EXAMPLE
    .\Get-EnterpriseAppProvisioningAudit.ps1
    Audits every provisioning job in the tenant, 7-day failure lookback.

.EXAMPLE
    .\Get-EnterpriseAppProvisioningAudit.ps1 -AppDisplayName "Salesforce" -FailureLookbackDays 14

.NOTES
    Requires: Microsoft.Graph.Applications, Microsoft.Graph.Reports modules
    Run as: any account with Application.Read.All + AuditLog.Read.All (Global Reader is
            NOT sufficient — it cannot read provisioning configuration; use a custom role
            with microsoft.directory/applications/synchronization/standard/read, or a
            built-in role such as Cloud Application Administrator / Application Administrator)
    Safe/unsafe: fully read-only. No write, restart, or credential operations are performed.
#>

[CmdletBinding()]
param(
    [string]$AppDisplayName,
    [int]$FailureLookbackDays = 7,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ------------------------------------------------------------
$requiredModules = @("Microsoft.Graph.Applications", "Microsoft.Graph.Reports")
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Status "Required module '$m' not found. Install with: Install-Module $m -Scope CurrentUser" "ERROR"
        return
    }
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'Application.Read.All','AuditLog.Read.All'" "ERROR"
    return
}
Write-Status "Connected as $($context.Account) — scopes: $($context.Scopes -join ', ')" "OK"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---- Detect --------------------------------------------------------------
Write-Status "Enumerating Service Principals with provisioning configured..."

if ($AppDisplayName) {
    $servicePrincipals = @(Get-MgServicePrincipal -Filter "displayName eq '$AppDisplayName'" -All)
    if ($servicePrincipals.Count -eq 0) {
        Write-Status "No Service Principal found matching displayName '$AppDisplayName'." "ERROR"
        return
    }
} else {
    # Pull all SPs, then filter down to ones with at least one synchronization job.
    # This is intentionally a two-pass approach (list all, then probe each) since
    # there is no server-side filter for "has a synchronization job configured."
    $servicePrincipals = @(Get-MgServicePrincipal -All -Property "id,displayName,appId")
}

$results = New-Object System.Collections.Generic.List[Object]
$failureSummaries = New-Object System.Collections.Generic.List[Object]
$probed = 0
$found = 0

foreach ($sp in $servicePrincipals) {
    $probed++
    if ($probed % 200 -eq 0) { Write-Status "Probed $probed / $($servicePrincipals.Count) service principals..." }

    try {
        $jobs = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue
    } catch {
        continue
    }
    if (-not $jobs) { continue }

    foreach ($job in $jobs) {
        $found++
        $status = $job.Status

        $ageDays = $null
        if ($status.LastSuccessfulExecution.Time) {
            $ageDays = [math]::Round(((Get-Date) - $status.LastSuccessfulExecution.Time).TotalDays, 1)
        }

        $healthFlag = switch ($true) {
            { $status.Code -eq "Quarantine" }               { "QUARANTINE"; break }
            { $status.Code -eq "Paused" }                    { "PAUSED"; break }
            { $status.Code -eq "NotStarted" }                { "NOT_STARTED"; break }
            { $ageDays -ne $null -and $ageDays -gt 3 }       { "STALE_LAST_SUCCESS"; break }
            { $status.Code -eq "Active" }                     { "OK"; break }
            default                                           { "UNKNOWN" }
        }

        $results.Add([PSCustomObject]@{
            AppDisplayName          = $sp.DisplayName
            ServicePrincipalId      = $sp.Id
            AppId                   = $sp.AppId
            JobId                   = $job.Id
            StatusCode              = $status.Code
            QuarantineReason        = $status.QuarantineReason
            LastSuccessfulExecution = $status.LastSuccessfulExecution.Time
            LastExecution           = $status.LastExecution.Time
            DaysSinceLastSuccess    = $ageDays
            HealthFlag              = $healthFlag
        })

        # Pull recent failures for this job, grouped by reason, for the ones that look unhealthy
        if ($healthFlag -ne "OK") {
            try {
                $since = (Get-Date).AddDays(-$FailureLookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
                $failures = Get-MgAuditLogProvisioning `
                    -Filter "servicePrincipalId eq '$($sp.Id)' and provisioningStatusStatus eq 'failure' and activityDateTime ge $since" `
                    -Top 500 -ErrorAction SilentlyContinue

                if ($failures) {
                    $grouped = $failures | Group-Object { $_.ProvisioningStatus.StatusInfo.AdditionalDetails } |
                        Sort-Object Count -Descending | Select-Object -First 5

                    foreach ($g in $grouped) {
                        $failureSummaries.Add([PSCustomObject]@{
                            AppDisplayName = $sp.DisplayName
                            FailureCount   = $g.Count
                            FailureReason  = $g.Name
                        })
                    }
                }
            } catch {
                Write-Status "Could not pull provisioning logs for $($sp.DisplayName): $($_.Exception.Message)" "WARN"
            }
        }
    }
}

Write-Status "Found $found provisioning job(s) across $probed service principal(s) probed." "OK"

# ---- Report ----------------------------------------------------------------
$unhealthy = $results | Where-Object HealthFlag -ne "OK"
if ($unhealthy) {
    Write-Status "$($unhealthy.Count) job(s) flagged unhealthy:" "WARN"
    $unhealthy | Format-Table AppDisplayName, StatusCode, QuarantineReason, DaysSinceLastSuccess, HealthFlag -AutoSize
} else {
    Write-Status "All discovered provisioning jobs report healthy (Active, recent last-success)." "OK"
}

$jobsCsv = Join-Path $OutputPath "ProvisioningJobs_$timestamp.csv"
$results | Export-Csv -Path $jobsCsv -NoTypeInformation
Write-Status "Job inventory exported: $jobsCsv" "OK"

if ($failureSummaries.Count -gt 0) {
    $failuresCsv = Join-Path $OutputPath "ProvisioningFailureSummary_$timestamp.csv"
    $failureSummaries | Export-Csv -Path $failuresCsv -NoTypeInformation
    Write-Status "Failure-reason summary exported: $failuresCsv" "OK"
}

Write-Status "Audit complete. This script made no configuration changes." "OK"
