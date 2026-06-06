<#
.SYNOPSIS
    Generates a comprehensive Universal Print health and usage report.

.DESCRIPTION
    Queries the Universal Print service via Microsoft Graph to produce:
    - Printer and printer share inventory (online/offline status)
    - Connector status per printer
    - Job queue summary (queued, processing, completed, failed) per printer
    - User/group access assignments per printer share
    - Recent print job failures with error codes
    - Printers with no jobs in the last N days (potential dead printers)

    Output is written to CSV files and a summary to the console.
    Requires the Universal Print service to be licensed in the tenant.

.PARAMETER OutputPath
    Folder where CSV reports are saved. Default: C:\UPReport_<timestamp>

.PARAMETER DaysBack
    Number of days of job history to query. Default: 30. Max recommended: 30 (Graph throttles beyond this).

.PARAMETER InactiveDays
    Flag printers as "inactive" if no successful jobs in this many days. Default: 14.

.EXAMPLE
    .\Get-UniversalPrintReport.ps1
    Run with defaults, output to C:\UPReport_20260606_120000

.EXAMPLE
    .\Get-UniversalPrintReport.ps1 -OutputPath "C:\Reports\UP" -DaysBack 7 -InactiveDays 7
    One-week snapshot, flag printers with no jobs in 7 days.

.NOTES
    Required Graph scopes: Printer.Read.All, PrintJob.Read.All, PrintSettings.Read.All
    Required role: Printer Administrator or Global Reader
    Requires: Microsoft.Graph PowerShell SDK (Install-Module Microsoft.Graph)
    Does NOT require admin consent for Printer.Read.All in most tenants — check your Graph app consent.
#>
[CmdletBinding()]
param(
    [string]$OutputPath   = "C:\UPReport_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [ValidateRange(1, 30)]
    [int]$DaysBack        = 30,
    [int]$InactiveDays    = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        default { "Cyan"   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region --- Preflight ---
Write-Status "Universal Print Report — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Status "Checking Microsoft.Graph module..."

$requiredModules = @("Microsoft.Graph.Devices.CloudPrint", "Microsoft.Graph.Authentication")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Installing $mod..." "WARN"
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    }
}

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Printer.Read.All", "PrintJob.Read.All", "PrintSettings.Read.All" -NoWelcome

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Write-Status "Output folder: $OutputPath" "OK"
#endregion

#region --- Collect Printers ---
Write-Status "Collecting printer inventory..."
$printers = Get-MgPrint -ExpandProperty Shares |
    ForEach-Object {
        # Get printer details including connectors
        Get-MgPrinter -PrinterId $_.Id -ExpandProperty Connectors
    }

Write-Status "Found $($printers.Count) printers" "OK"

$printerReport = foreach ($p in $printers) {
    $connectorStatus = if ($p.Connectors) {
        ($p.Connectors | ForEach-Object {
            "$($_.DisplayName):$($_.OperatingSystem):$( if ($p.IsAcceptingJobs) {'online'} else {'offline'} )"
        }) -join " | "
    } else { "NoConnector" }

    [PSCustomObject]@{
        PrinterId       = $p.Id
        DisplayName     = $p.DisplayName
        Manufacturer    = $p.Manufacturer
        Model           = $p.Model
        Location        = $p.Location.Building + " / " + $p.Location.FloorDescription
        IsShared        = ($p.Shares.Count -gt 0)
        ShareCount      = $p.Shares.Count
        ShareNames      = ($p.Shares | ForEach-Object { $_.DisplayName }) -join ", "
        IsAcceptingJobs = $p.IsAcceptingJobs
        Status          = if ($p.IsAcceptingJobs) { "Online" } else { "Offline" }
        ConnectorCount  = $p.Connectors.Count
        ConnectorDetail = $connectorStatus
    }
}

$printerReport | Export-Csv "$OutputPath\1_PrinterInventory.csv" -NoTypeInformation
Write-Status "Printer inventory saved ($($printerReport.Count) printers)" "OK"
#endregion

#region --- Printer Share Access ---
Write-Status "Collecting printer share access assignments..."
$shareReport = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($p in $printers) {
    foreach ($share in $p.Shares) {
        try {
            $shareDetail = Get-MgPrintPrinterShare -PrinterShareId $share.Id
            $allowedUsers  = Get-MgPrintPrinterShareAllowedUser  -PrinterShareId $share.Id -ErrorAction SilentlyContinue
            $allowedGroups = Get-MgPrintPrinterShareAllowedGroup -PrinterShareId $share.Id -ErrorAction SilentlyContinue

            $shareReport.Add([PSCustomObject]@{
                PrinterName   = $p.DisplayName
                ShareId       = $share.Id
                ShareName     = $share.DisplayName
                AllowAllUsers = $shareDetail.AllowAllUsers
                AllowedUsers  = ($allowedUsers | ForEach-Object { $_.UserPrincipalName }) -join ", "
                AllowedGroups = ($allowedGroups | ForEach-Object { $_.DisplayName }) -join ", "
            })
        } catch {
            Write-Status "Could not retrieve share details for: $($share.DisplayName) — $($_.Exception.Message)" "WARN"
        }
    }
}

$shareReport | Export-Csv "$OutputPath\2_ShareAccessAssignments.csv" -NoTypeInformation
Write-Status "Share access report saved ($($shareReport.Count) shares)" "OK"
#endregion

#region --- Job Summary per Printer ---
Write-Status "Collecting print job summary (last $DaysBack days)..."
$startDate = (Get-Date).AddDays(-$DaysBack).ToString("yyyy-MM-ddTHH:mm:ssZ")
$jobSummary = [System.Collections.Generic.List[PSCustomObject]]::new()
$failedJobs = [System.Collections.Generic.List[PSCustomObject]]::new()
$lastJobDate = @{}

foreach ($p in $printers) {
    try {
        # Graph: list print jobs for this printer filtered by date
        $jobs = Get-MgPrinterJob -PrinterId $p.Id -All -Filter "createdDateTime ge $startDate" -ErrorAction SilentlyContinue

        if (-not $jobs) {
            $jobs = @()
        }

        $total        = $jobs.Count
        $completed    = ($jobs | Where-Object { $_.Status.State -eq "completed" }).Count
        $failed       = ($jobs | Where-Object { $_.Status.State -in @("aborted", "failed") }).Count
        $processing   = ($jobs | Where-Object { $_.Status.State -in @("processing", "pending") }).Count

        # Track last successful job
        $lastSuccessful = $jobs | Where-Object { $_.Status.State -eq "completed" } |
            Sort-Object CreatedDateTime -Descending | Select-Object -First 1
        $lastJobDate[$p.Id] = $lastSuccessful.CreatedDateTime

        $jobSummary.Add([PSCustomObject]@{
            PrinterName      = $p.DisplayName
            PrinterId        = $p.Id
            TotalJobs        = $total
            Completed        = $completed
            Failed           = $failed
            Processing       = $processing
            LastSuccessfulJob = $lastSuccessful.CreatedDateTime
            DaysSinceLastJob = if ($lastSuccessful) {
                [int](New-TimeSpan -Start $lastSuccessful.CreatedDateTime).TotalDays
            } else { "NoJobsInPeriod" }
            IsInactive       = (-not $lastSuccessful) -or
                               ((New-TimeSpan -Start $lastSuccessful.CreatedDateTime).TotalDays -gt $InactiveDays)
        })

        # Capture failed job details
        foreach ($job in ($jobs | Where-Object { $_.Status.State -in @("aborted", "failed") })) {
            $failedJobs.Add([PSCustomObject]@{
                PrinterName  = $p.DisplayName
                JobId        = $job.Id
                CreatedAt    = $job.CreatedDateTime
                CreatedBy    = $job.CreatedBy.UserPrincipalName
                State        = $job.Status.State
                Description  = $job.Status.Description
                ErrorCode    = ($job.Status.Details -join "; ")
            })
        }
    } catch {
        Write-Status "Job query failed for printer: $($p.DisplayName) — $($_.Exception.Message)" "WARN"
    }
}

$jobSummary | Export-Csv "$OutputPath\3_JobSummaryPerPrinter.csv" -NoTypeInformation
$failedJobs | Export-Csv "$OutputPath\4_FailedJobs.csv" -NoTypeInformation
Write-Status "Job summary saved. Failed jobs: $($failedJobs.Count)" "OK"
#endregion

#region --- Inactive Printers ---
$inactive = $jobSummary | Where-Object { $_.IsInactive -eq $true }
if ($inactive) {
    $inactive | Export-Csv "$OutputPath\5_InactivePrinters.csv" -NoTypeInformation
    Write-Status "$($inactive.Count) inactive printers (no successful jobs in $InactiveDays days)" "WARN"
} else {
    Write-Status "No inactive printers found" "OK"
}
#endregion

#region --- Offline Printers ---
$offline = $printerReport | Where-Object { $_.Status -eq "Offline" }
if ($offline) {
    $offline | Export-Csv "$OutputPath\6_OfflinePrinters.csv" -NoTypeInformation
    Write-Status "$($offline.Count) printers currently OFFLINE" "WARN"
} else {
    Write-Status "All printers online" "OK"
}
#endregion

#region --- Console Summary ---
Write-Host "`n========== UNIVERSAL PRINT REPORT SUMMARY ==========" -ForegroundColor Cyan
Write-Host "Report period   : Last $DaysBack days (since $startDate)"
Write-Host "Output folder   : $OutputPath"
Write-Host ""
Write-Host "PRINTERS" -ForegroundColor Yellow
Write-Host "  Total         : $($printers.Count)"
Write-Host "  Online        : $(($printerReport | Where-Object { $_.Status -eq 'Online' }).Count)"
Write-Host "  Offline       : $($offline.Count)" -ForegroundColor $(if ($offline.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  Shared        : $(($printerReport | Where-Object { $_.IsShared }).Count)"
Write-Host "  No connector  : $(($printerReport | Where-Object { $_.ConnectorCount -eq 0 }).Count)"
Write-Host ""
Write-Host "PRINT JOBS" -ForegroundColor Yellow
$totalJobs      = ($jobSummary | Measure-Object -Property TotalJobs -Sum).Sum
$totalCompleted = ($jobSummary | Measure-Object -Property Completed -Sum).Sum
$totalFailed    = ($jobSummary | Measure-Object -Property Failed -Sum).Sum
Write-Host "  Total jobs    : $totalJobs"
Write-Host "  Completed     : $totalCompleted"
Write-Host "  Failed        : $totalFailed" -ForegroundColor $(if ($totalFailed -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Inactive (>$InactiveDays d): $($inactive.Count)" -ForegroundColor $(if ($inactive.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host ""
Write-Host "FILES GENERATED" -ForegroundColor Yellow
Get-ChildItem -Path $OutputPath -Filter "*.csv" | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host "=====================================================" -ForegroundColor Cyan
#endregion
