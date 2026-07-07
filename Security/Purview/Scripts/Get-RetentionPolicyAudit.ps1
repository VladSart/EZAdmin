<#
.SYNOPSIS
    Audits Microsoft Purview retention labels and retention label policies tenant-wide, flagging
    unpublished labels, stuck distribution, orphaned locations, and irreversible record labels.

.DESCRIPTION
    Automates the Validation Steps and Diagnosis & Validation Flow from RetentionLabels-A.md /
    RetentionLabels-B.md so an admin gets one consolidated report instead of walking every label
    and policy individually in the compliance portal.

    Covers:
    - Every retention label (compliance tag) in the tenant: retention action, duration, clock
      type (RetentionType), and record/regulatory flags
    - UNPUBLISHED_LABEL flag when a label has zero matching retention label policies — the #1
      root cause of "label doesn't show up for anyone" tickets (per RetentionLabels-B.md Fix 2)
    - DISTRIBUTION_ERROR flag when a policy's DistributionStatus is Error, or when
      Exchange/SharePoint/OneDrive location-exception properties are populated (a specific
      deleted/inaccessible location, not a wholesale failure)
    - DISTRIBUTION_PENDING_STALE flag when a policy has sat in Pending status longer than a
      configurable threshold — new publishes take up to 7 days to fully propagate per Microsoft's
      own guidance, so this only fires past that window, not on every Pending result
    - REGULATORY_RECORD_REVIEW flag on every label marked Regulatory = $true, since that state is
      permanently irreversible once applied to content — surfaced for deliberate sign-off review,
      not because it's inherently wrong
      - MODIFICATION_CLOCK_LABEL flag on labels using RetentionType = ModificationAgeInDays, purely
      informational — this is the single most common "why hasn't this expired yet" root cause
      when a client reports a document that should have disposed but hasn't (its clock keeps
      resetting on every edit)
    - Adaptive scope freshness check (if any policy uses one) against a configurable staleness
      threshold, since scopes re-evaluate on a schedule rather than in real time

    Does NOT cover:
    - Per-item label application forensics (requires Search-UnifiedAuditLog against a specific
      item; see RetentionLabels-B.md Diagnosis Step 5 for that targeted, one-off workflow)
    - Disposition review stage/reviewer-chain configuration (portal-only surface not exposed via
      Get-ComplianceTag; see RetentionLabels-A.md Troubleshooting Phase 4)
    - Container-level (non-label) retention policy conflict resolution against a specific mailbox
      or site — this script inventories policies but does not compute the effective winner for a
      given item, since that requires the 3-rule model applied case-by-case (see
      RetentionLabels-A.md How It Works)

.PARAMETER PendingDistributionDaysThreshold
    Days a policy can sit in "Pending" distribution status before being flagged
    DISTRIBUTION_PENDING_STALE. Default: 7 (Microsoft's own documented full-rollout window).

.PARAMETER AdaptiveScopeStaleDaysThreshold
    Days since an adaptive scope's last query before flagging ADAPTIVE_SCOPE_STALE.
    Default: 3.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-RetentionPolicyAudit.ps1 -OutputPath C:\Temp\RetentionAudit

.EXAMPLE
    .\Get-RetentionPolicyAudit.ps1 -PendingDistributionDaysThreshold 10 -AdaptiveScopeStaleDaysThreshold 5

.NOTES
    Requires:
    - ExchangeOnlineManagement module (Connect-IPPSSession)
    - Records Management, Compliance Administrator, or Global Administrator role for a complete
      tenant-wide view of all labels and policies

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No labels, policies, or retention settings are created, changed, or
    retried by this script — DISTRIBUTION_ERROR/STALE findings must be actioned manually via
    Set-RetentionCompliancePolicy -RetryDistribution or Set-AppRetentionCompliancePolicy
    -RetryDistribution per RetentionLabels-B.md Fix 1.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$PendingDistributionDaysThreshold = 7,

    [Parameter()]
    [int]$AdaptiveScopeStaleDaysThreshold = 3,

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

function Get-LabelAudit {
    param([object[]]$AllPolicies)

    Write-Status "Retrieving all retention labels (compliance tags)..." "INFO"
    $labels = Get-ComplianceTag -ErrorAction Stop
    Write-Status "Found $($labels.Count) labels" "OK"

    $report = [System.Collections.Generic.List[object]]::new()

    foreach ($label in $labels) {
        $flags = [System.Collections.Generic.List[string]]::new()

        $matchingPolicies = $AllPolicies | Where-Object { $_.Name -like "*$($label.Name)*" }
        if (-not $matchingPolicies -or $matchingPolicies.Count -eq 0) {
            $flags.Add("UNPUBLISHED_LABEL")
        }

        if ($label.Regulatory) {
            $flags.Add("REGULATORY_RECORD_REVIEW")
        }
        elseif ($label.IsRecordLabel) {
            $flags.Add("RECORD_LABEL_REVIEW")
        }

        if ($label.RetentionType -eq "ModificationAgeInDays") {
            $flags.Add("MODIFICATION_CLOCK_LABEL")
        }

        $report.Add([PSCustomObject]@{
            LabelName        = $label.Name
            RetentionAction  = $label.RetentionAction
            RetentionDuration = $label.RetentionDuration
            RetentionType    = $label.RetentionType
            IsRecordLabel    = $label.IsRecordLabel
            Regulatory       = $label.Regulatory
            ReviewerEmail    = ($label.ReviewerEmail -join "; ")
            PublishingPolicyCount = ($matchingPolicies | Measure-Object).Count
            Flags            = ($flags -join "; ")
        })
    }

    return $report
}

function Get-PolicyDistributionAudit {
    param(
        [object[]]$AllPolicies,
        [int]$PendingThresholdDays
    )

    Write-Status "Auditing retention label policy distribution status..." "INFO"

    $report = [System.Collections.Generic.List[object]]::new()

    foreach ($policy in $AllPolicies) {
        $flags = [System.Collections.Generic.List[string]]::new()

        if ($policy.DistributionStatus -eq "Error") {
            $flags.Add("DISTRIBUTION_ERROR")
        }

        if ($policy.DistributionStatus -eq "Pending" -and $policy.WhenChanged) {
            $age = (Get-Date) - $policy.WhenChanged
            if ($age.TotalDays -gt $PendingThresholdDays) {
                $flags.Add("DISTRIBUTION_PENDING_STALE")
            }
        }

        $exchangeExceptionCount   = if ($policy.ExchangeLocationException)   { ($policy.ExchangeLocationException   | Measure-Object).Count } else { 0 }
        $sharePointExceptionCount = if ($policy.SharePointLocationException) { ($policy.SharePointLocationException | Measure-Object).Count } else { 0 }
        $oneDriveExceptionCount   = if ($policy.OneDriveLocationException)   { ($policy.OneDriveLocationException   | Measure-Object).Count } else { 0 }

        if (($exchangeExceptionCount + $sharePointExceptionCount + $oneDriveExceptionCount) -gt 0) {
            $flags.Add("LOCATION_EXCEPTION_FOUND")
        }

        if (-not $policy.Enabled) {
            $flags.Add("POLICY_DISABLED")
        }

        $report.Add([PSCustomObject]@{
            PolicyName          = $policy.Name
            Enabled             = $policy.Enabled
            Mode                = $policy.Mode
            DistributionStatus  = $policy.DistributionStatus
            WhenChanged         = $policy.WhenChanged
            ExchangeExceptions  = $exchangeExceptionCount
            SharePointExceptions = $sharePointExceptionCount
            OneDriveExceptions  = $oneDriveExceptionCount
            Flags               = ($flags -join "; ")
        })
    }

    return $report
}

function Get-AdaptiveScopeAudit {
    param([int]$StaleThresholdDays)

    Write-Status "Checking adaptive scope freshness..." "INFO"
    try {
        $scopes = Get-AdaptiveScope -ErrorAction Stop
    }
    catch {
        Write-Status "Could not retrieve adaptive scopes (may not be licensed/configured in this tenant): $($_.Exception.Message)" "WARN"
        return @()
    }

    if (-not $scopes -or $scopes.Count -eq 0) {
        Write-Status "No adaptive scopes found in this tenant." "INFO"
        return @()
    }

    $report = foreach ($scope in $scopes) {
        $flag = "OK"
        if ($scope.LastQueryTime) {
            $age = (Get-Date) - $scope.LastQueryTime
            if ($age.TotalDays -gt $StaleThresholdDays) {
                $flag = "ADAPTIVE_SCOPE_STALE"
            }
        }
        else {
            $flag = "NEVER_QUERIED"
        }

        [PSCustomObject]@{
            ScopeName     = $scope.Name
            ScopeType     = $scope.ScopeType
            LastQueryTime = $scope.LastQueryTime
            Flag          = $flag
        }
    }

    return $report
}

function Write-SummaryReport {
    param(
        [object[]]$LabelReport,
        [object[]]$PolicyReport,
        [object[]]$ScopeReport
    )

    $separator = "=" * 60
    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  RETENTION LABEL & POLICY AUDIT" -ForegroundColor Cyan
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[ LABEL SUMMARY ]" -ForegroundColor Yellow
    Write-Host "  Total labels audited: $($LabelReport.Count)"
    $unpublished = $LabelReport | Where-Object { $_.Flags -like "*UNPUBLISHED_LABEL*" }
    $regulatory  = $LabelReport | Where-Object { $_.Flags -like "*REGULATORY_RECORD_REVIEW*" }
    $records     = $LabelReport | Where-Object { $_.Flags -like "*RECORD_LABEL_REVIEW*" }
    $modClock    = $LabelReport | Where-Object { $_.Flags -like "*MODIFICATION_CLOCK_LABEL*" }
    Write-Status "  UNPUBLISHED_LABEL (invisible to all users): $($unpublished.Count)" $(if ($unpublished.Count -gt 0) { "WARN" } else { "OK" })
    Write-Status "  REGULATORY_RECORD_REVIEW (permanently irreversible): $($regulatory.Count)" $(if ($regulatory.Count -gt 0) { "WARN" } else { "OK" })
    Write-Status "  RECORD_LABEL_REVIEW: $($records.Count)" "INFO"
    Write-Status "  MODIFICATION_CLOCK_LABEL (clock resets on edit): $($modClock.Count)" "INFO"
    Write-Host ""

    if ($unpublished.Count -gt 0) {
        Write-Host "[ UNPUBLISHED LABELS — invisible to every user until a policy publishes them ]" -ForegroundColor Yellow
        $unpublished | Select-Object LabelName, RetentionAction | Format-Table -AutoSize
    }

    Write-Host "[ POLICY DISTRIBUTION SUMMARY ]" -ForegroundColor Yellow
    Write-Host "  Total policies audited: $($PolicyReport.Count)"
    $errorPolicies = $PolicyReport | Where-Object { $_.Flags -like "*DISTRIBUTION_ERROR*" }
    $stalePolicies = $PolicyReport | Where-Object { $_.Flags -like "*DISTRIBUTION_PENDING_STALE*" }
    $exceptionPolicies = $PolicyReport | Where-Object { $_.Flags -like "*LOCATION_EXCEPTION_FOUND*" }
    Write-Status "  DISTRIBUTION_ERROR: $($errorPolicies.Count)" $(if ($errorPolicies.Count -gt 0) { "WARN" } else { "OK" })
    Write-Status "  DISTRIBUTION_PENDING_STALE (>$PendingDistributionDaysThreshold days): $($stalePolicies.Count)" $(if ($stalePolicies.Count -gt 0) { "WARN" } else { "OK" })
    Write-Status "  LOCATION_EXCEPTION_FOUND: $($exceptionPolicies.Count)" $(if ($exceptionPolicies.Count -gt 0) { "WARN" } else { "OK" })
    Write-Host ""

    if (($errorPolicies.Count + $stalePolicies.Count) -gt 0) {
        Write-Host "[ POLICIES NEEDING ATTENTION — see RetentionLabels-B.md Fix 1 ]" -ForegroundColor Yellow
        ($errorPolicies + $stalePolicies) | Select-Object PolicyName, DistributionStatus, Flags -Unique | Format-Table -AutoSize
    }

    if ($ScopeReport.Count -gt 0) {
        Write-Host "[ ADAPTIVE SCOPE FRESHNESS ]" -ForegroundColor Yellow
        $stale = $ScopeReport | Where-Object { $_.Flag -ne "OK" }
        if ($stale.Count -gt 0) {
            $stale | Format-Table -AutoSize
        } else {
            Write-Host "  All adaptive scopes queried within the staleness threshold." -ForegroundColor Green
        }
    }
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting Retention Label & Policy Audit..." "INFO"

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
    Write-Status "Ensure you hold Records Management, Compliance Administrator, or Global Administrator for a complete audit" "WARN"
    exit 1
}

Write-Status "Retrieving all retention label policies (Exchange/SharePoint/OneDrive)..." "INFO"
$allPolicies = Get-RetentionCompliancePolicy -ErrorAction Stop
Write-Status "Found $($allPolicies.Count) policies" "OK"

$labelReport  = Get-LabelAudit -AllPolicies $allPolicies
$policyReport = Get-PolicyDistributionAudit -AllPolicies $allPolicies -PendingThresholdDays $PendingDistributionDaysThreshold
$scopeReport  = Get-AdaptiveScopeAudit -StaleThresholdDays $AdaptiveScopeStaleDaysThreshold

Write-SummaryReport -LabelReport $labelReport -PolicyReport $policyReport -ScopeReport $scopeReport

$stamp = Get-Date -Format 'yyyyMMdd'

if ($labelReport.Count -gt 0) {
    $labelFile = Join-Path $OutputPath "RetentionLabel-Audit-$stamp.csv"
    $labelReport | Export-Csv -Path $labelFile -NoTypeInformation -Encoding UTF8
    Write-Status "Label audit exported to: $labelFile" "OK"
}

if ($policyReport.Count -gt 0) {
    $policyFile = Join-Path $OutputPath "RetentionPolicy-Distribution-$stamp.csv"
    $policyReport | Export-Csv -Path $policyFile -NoTypeInformation -Encoding UTF8
    Write-Status "Policy distribution audit exported to: $policyFile" "OK"
}

if ($scopeReport.Count -gt 0) {
    $scopeFile = Join-Path $OutputPath "AdaptiveScope-Freshness-$stamp.csv"
    $scopeReport | Export-Csv -Path $scopeFile -NoTypeInformation -Encoding UTF8
    Write-Status "Adaptive scope freshness exported to: $scopeFile" "OK"
}

Write-Status "Retention label & policy audit complete. Files written to: $OutputPath" "OK"
