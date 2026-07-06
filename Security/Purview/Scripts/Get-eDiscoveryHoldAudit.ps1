<#
.SYNOPSIS
    Audits all Microsoft Purview eDiscovery cases and their hold policies tenant-wide, flagging
    stuck distribution, orphaned locations, and expiring exports.

.DESCRIPTION
    Automates Playbook 2 ("Audit all active holds in the tenant") from eDiscovery-A.md and
    extends it with the failure-mode checks called out in the runbook's Symptom → Cause Map,
    so a compliance admin gets one report instead of walking each case individually.

    Covers:
    - Every case (Core and Premium), active and closed
    - Every hold policy per case: status, enabled state, location counts
    - HOLD_ERROR flag when a hold has ExchangeLocationException / SharePointLocationException
      entries (per eDiscovery-A.md: usually a deleted, renamed, or migrated mailbox/site)
    - HOLD_PENDING_STALE flag when a hold has sat in Pending status longer than a configurable
      threshold (normal propagation is 1-24h; anything past 48h suggests a distribution backlog)
    - EXPORT_EXPIRING / EXPORT_EXPIRED flags on recent export jobs — the Azure Blob staging area
      expires after 30 days and must be recreated (eDiscovery-A.md Export Mechanics)
    - Role group membership snapshot for eDiscovery Manager / Administrator, since "You don't
      have permission to view this case" is almost always a role-group or case-membership gap,
      not a broken case

    Does NOT cover:
    - Content search execution or KQL validation (see eDiscovery-A.md Phase 3 for that workflow)
    - On-premises Exchange In-Place eDiscovery (deprecated, out of scope per the runbook)

.PARAMETER PendingHoldHoursThreshold
    Hours a hold can sit in "Pending" before being flagged HOLD_PENDING_STALE. Default: 48.

.PARAMETER ExportExpiryWarningDays
    Days before the 30-day export staging expiry to raise an EXPORT_EXPIRING warning.
    Default: 5 (i.e. warns starting at day 25).

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-eDiscoveryHoldAudit.ps1 -OutputPath C:\Temp\eDiscoveryAudit

.EXAMPLE
    .\Get-eDiscoveryHoldAudit.ps1 -PendingHoldHoursThreshold 24 -ExportExpiryWarningDays 7

.NOTES
    Requires:
    - ExchangeOnlineManagement module (Connect-IPPSSession)
    - eDiscovery Administrator role (to see all cases tenant-wide; eDiscovery Manager only
      sees cases they are a member of and will produce an incomplete report)

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to cases, holds, or exports.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$PendingHoldHoursThreshold = 48,

    [Parameter()]
    [ValidateRange(1, 29)]
    [int]$ExportExpiryWarningDays = 5,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
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

function Get-CaseHoldAudit {
    param([int]$PendingThresholdHours)

    Write-Status "Retrieving all eDiscovery cases (active and closed)..." "INFO"
    $allCases = Get-ComplianceCase -State All -ErrorAction Stop
    Write-Status "Found $($allCases.Count) cases" "OK"

    $report = [System.Collections.Generic.List[object]]::new()

    foreach ($case in $allCases) {
        $holds = Get-CaseHoldPolicy -Case $case.Name -ErrorAction SilentlyContinue
        if (-not $holds) { continue }

        foreach ($hold in $holds) {
            $flags = [System.Collections.Generic.List[string]]::new()

            $hasExchangeException  = $hold.ExchangeLocationException  -and $hold.ExchangeLocationException.Count -gt 0
            $hasSharePointException = $hold.SharePointLocationException -and $hold.SharePointLocationException.Count -gt 0
            if ($hasExchangeException -or $hasSharePointException) {
                $flags.Add("HOLD_ERROR")
            }

            if ($hold.Status -eq "Pending" -and $hold.EnabledDate) {
                $age = (Get-Date) - $hold.EnabledDate
                if ($age.TotalHours -gt $PendingThresholdHours) {
                    $flags.Add("HOLD_PENDING_STALE")
                }
            }

            if (-not $hold.IsEnabled) {
                $flags.Add("HOLD_DISABLED")
            }

            $report.Add([PSCustomObject]@{
                CaseName            = $case.Name
                CaseStatus          = $case.Status
                HoldName            = $hold.Name
                HoldStatus          = $hold.Status
                HoldEnabled         = $hold.IsEnabled
                ExchangeLocations   = ($hold.ExchangeLocation | Measure-Object).Count
                SharePointLocations = ($hold.SharePointLocation | Measure-Object).Count
                EnabledDate         = $hold.EnabledDate
                Flags               = ($flags -join "; ")
            })
        }
    }

    return $report
}

function Get-ExportExpiryAudit {
    param([int]$WarningDays)

    Write-Status "Checking export job staging expiry (30-day Azure Blob limit)..." "INFO"
    try {
        $exports = Get-ComplianceSearchAction -Export -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to retrieve export actions: $($_.Exception.Message)" "WARN"
        return @()
    }

    $report = foreach ($export in $exports) {
        if (-not $export.JobEndTime) { continue }
        $age         = (Get-Date) - $export.JobEndTime
        $daysLeft    = 30 - [math]::Floor($age.TotalDays)
        $flag = if ($daysLeft -le 0) { "EXPORT_EXPIRED" }
                elseif ($daysLeft -le $WarningDays) { "EXPORT_EXPIRING" }
                else { "OK" }

        [PSCustomObject]@{
            ExportName       = $export.Name
            Status           = $export.Status
            JobEndTime       = $export.JobEndTime
            ExportSizeBytes  = $export.ExportSizeInBytes
            DaysUntilExpiry  = $daysLeft
            Flag             = $flag
        }
    }

    return $report
}

function Get-RoleGroupSnapshot {
    Write-Status "Snapshotting eDiscovery role group membership..." "INFO"
    $snapshot = [System.Collections.Generic.List[object]]::new()

    foreach ($rg in @("eDiscovery Manager", "eDiscovery Administrator")) {
        try {
            $members = Get-RoleGroupMember -Identity $rg -ErrorAction Stop
            foreach ($m in $members) {
                $snapshot.Add([PSCustomObject]@{
                    RoleGroup           = $rg
                    Member              = $m.Name
                    PrimarySmtpAddress  = $m.PrimarySmtpAddress
                })
            }
        }
        catch {
            Write-Status "Could not read role group '$rg': $($_.Exception.Message)" "WARN"
        }
    }

    return $snapshot
}

function Write-SummaryReport {
    param(
        [object[]]$HoldReport,
        [object[]]$ExportReport,
        [object[]]$RoleSnapshot
    )

    $separator = "=" * 60
    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  eDISCOVERY HOLD & EXPORT AUDIT" -ForegroundColor Cyan
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[ HOLD SUMMARY ]" -ForegroundColor Yellow
    Write-Host "  Total case holds audited: $($HoldReport.Count)"
    $errorHolds   = $HoldReport | Where-Object { $_.Flags -like "*HOLD_ERROR*" }
    $staleHolds   = $HoldReport | Where-Object { $_.Flags -like "*HOLD_PENDING_STALE*" }
    $disabledHolds = $HoldReport | Where-Object { $_.Flags -like "*HOLD_DISABLED*" }
    Write-Status "  HOLD_ERROR (location exceptions): $($errorHolds.Count)" $(if ($errorHolds.Count -gt 0) { "WARN" } else { "OK" })
    Write-Status "  HOLD_PENDING_STALE (>48h pending): $($staleHolds.Count)" $(if ($staleHolds.Count -gt 0) { "WARN" } else { "OK" })
    Write-Status "  HOLD_DISABLED: $($disabledHolds.Count)" "INFO"
    Write-Host ""

    if ($errorHolds.Count -gt 0) {
        Write-Host "[ HOLDS WITH LOCATION ERRORS ]" -ForegroundColor Yellow
        $errorHolds | Select-Object CaseName, HoldName, HoldStatus | Format-Table -AutoSize
    }

    Write-Host "[ EXPORT EXPIRY ]" -ForegroundColor Yellow
    if ($ExportReport.Count -eq 0) {
        Write-Host "  No export jobs found." -ForegroundColor Yellow
    } else {
        $expiring = $ExportReport | Where-Object { $_.Flag -in @("EXPORT_EXPIRING", "EXPORT_EXPIRED") }
        if ($expiring.Count -gt 0) {
            $expiring | Format-Table -AutoSize
        } else {
            Write-Host "  No exports expiring within the warning window." -ForegroundColor Green
        }
    }
    Write-Host ""

    Write-Host "[ ROLE GROUP MEMBERSHIP ]" -ForegroundColor Yellow
    $RoleSnapshot | Group-Object RoleGroup | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count) member(s)"
    }
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting eDiscovery Hold & Export Audit..." "INFO"

if (-not (Get-Module -Name ExchangeOnlineManagement -ListAvailable)) {
    Write-Status "ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement" "ERROR"
    exit 1
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path does not exist: $OutputPath — creating..." "WARN"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Connecting to Security & Compliance Center..." "INFO"
try {
    Connect-IPPSSession -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Status "Connected to S&C PowerShell" "OK"
}
catch {
    Write-Status "Failed to connect to Security & Compliance Center: $($_.Exception.Message)" "ERROR"
    Write-Status "Ensure you hold the eDiscovery Administrator role for a complete tenant-wide audit" "WARN"
    exit 1
}

$holdReport   = Get-CaseHoldAudit -PendingThresholdHours $PendingHoldHoursThreshold
$exportReport = Get-ExportExpiryAudit -WarningDays $ExportExpiryWarningDays
$roleSnapshot = Get-RoleGroupSnapshot

Write-SummaryReport -HoldReport $holdReport -ExportReport $exportReport -RoleSnapshot $roleSnapshot

$stamp = Get-Date -Format 'yyyyMMdd'

if ($holdReport.Count -gt 0) {
    $holdFile = Join-Path $OutputPath "eDiscovery-HoldAudit-$stamp.csv"
    $holdReport | Export-Csv -Path $holdFile -NoTypeInformation -Encoding UTF8
    Write-Status "Hold audit exported to: $holdFile" "OK"
}

if ($exportReport.Count -gt 0) {
    $exportFile = Join-Path $OutputPath "eDiscovery-ExportExpiry-$stamp.csv"
    $exportReport | Export-Csv -Path $exportFile -NoTypeInformation -Encoding UTF8
    Write-Status "Export expiry audit exported to: $exportFile" "OK"
}

if ($roleSnapshot.Count -gt 0) {
    $roleFile = Join-Path $OutputPath "eDiscovery-RoleGroups-$stamp.csv"
    $roleSnapshot | Export-Csv -Path $roleFile -NoTypeInformation -Encoding UTF8
    Write-Status "Role group snapshot exported to: $roleFile" "OK"
}

Write-Status "eDiscovery hold audit complete. Files written to: $OutputPath" "OK"
