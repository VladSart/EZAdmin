<#
.SYNOPSIS
    Generates a comprehensive Microsoft Purview DLP incident and policy report.

.DESCRIPTION
    Queries the Microsoft Purview / Security & Compliance Center for DLP policy match
    events, policy status, and rule configurations. Outputs a summary report and exports
    detailed incident data to CSV for review or escalation.

    Covers:
    - Active DLP policy list with enabled/disabled status
    - DLP policy matches from the Unified Audit Log (last N days)
    - Top triggered policies and rules
    - Top users with policy violations
    - Sensitive info type breakdown
    - Export to CSV for SIEM ingestion or management review

    Does NOT cover:
    - Insider Risk Management (separate workload)
    - Endpoint DLP device-side telemetry (requires separate MDE/Purview API)
    - Communication Compliance (separate workload)

.PARAMETER Days
    Number of days back to query from the Unified Audit Log. Default: 7. Max: 90.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.PARAMETER UserPrincipalName
    Optional. Filter results to a specific user UPN (for per-user investigation).

.PARAMETER PolicyName
    Optional. Filter results to a specific DLP policy name.

.PARAMETER ExportAll
    Switch. If specified, exports all raw audit events to a separate CSV in addition to the summary.

.EXAMPLE
    .\Get-PurviewDLPReport.ps1 -Days 30 -OutputPath C:\Temp\DLPReport

.EXAMPLE
    .\Get-PurviewDLPReport.ps1 -Days 7 -UserPrincipalName john.doe@contoso.com

.EXAMPLE
    .\Get-PurviewDLPReport.ps1 -Days 14 -PolicyName "PCI-DSS Policy" -ExportAll

.NOTES
    Requires:
    - ExchangeOnlineManagement module (Install-Module ExchangeOnlineManagement)
    - Compliance administrator or higher role in Microsoft 365
    - Unified Audit Log must be enabled in your tenant
    - Search-UnifiedAuditLog may take 15-30s per 5000 records

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to tenant configuration.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$Days = 7,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter()]
    [string]$UserPrincipalName = "",

    [Parameter()]
    [string]$PolicyName = "",

    [switch]$ExportAll
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

function Get-DLPPolicies {
    Write-Status "Retrieving DLP policies from Purview..." "INFO"
    try {
        $policies = Get-DlpCompliancePolicy -ErrorAction Stop
        return $policies
    }
    catch {
        Write-Status "Failed to retrieve DLP policies: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-DLPAuditEvents {
    param(
        [DateTime]$StartDate,
        [DateTime]$EndDate,
        [string]$UserFilter = "",
        [string]$PolicyFilter = ""
    )

    Write-Status "Querying Unified Audit Log for DLP events ($Days days)..." "INFO"
    Write-Status "This may take a while for large tenants..." "WARN"

    $allEvents = [System.Collections.Generic.List[object]]::new()
    $sessionId = "DLPReport-$(Get-Date -Format 'yyyyMMddHHmm')"
    $pageSize = 5000
    $retryCount = 0
    $maxRetries = 3

    do {
        try {
            $searchParams = @{
                StartDate   = $StartDate
                EndDate     = $EndDate
                RecordType  = "ComplianceDLPSharePoint", "ComplianceDLPExchange", "DLPEndpoint"
                ResultSize  = $pageSize
                SessionId   = $sessionId
                SessionCommand = "ReturnNextPreviewPage"
                ErrorAction = "Stop"
            }

            if ($UserFilter) { $searchParams['UserIds'] = $UserFilter }

            $results = Search-UnifiedAuditLog @searchParams
            if ($null -eq $results -or $results.Count -eq 0) { break }

            foreach ($event in $results) {
                $auditData = $event.AuditData | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($null -eq $auditData) { continue }

                # Apply policy filter if specified
                if ($PolicyFilter -and $auditData.PolicyName -notlike "*$PolicyFilter*") { continue }

                $allEvents.Add([PSCustomObject]@{
                    TimeStamp         = $event.CreationDate
                    User              = $event.UserIds
                    Workload          = $event.RecordType
                    PolicyName        = $auditData.PolicyName
                    RuleName          = $auditData.RuleName
                    Action            = $auditData.DlpRuleResult
                    SensitiveInfoTypes = ($auditData.SensitiveInfoTypeData | ForEach-Object { $_.SensitiveInfoTypeName }) -join "; "
                    MatchCount        = ($auditData.SensitiveInfoTypeData | Measure-Object -Property Count -Sum).Sum
                    Location          = $auditData.Location
                    FileName          = $auditData.ObjectName
                    SharepointSiteUrl = $auditData.SiteUrl
                    AlertTriggered    = if ($auditData.DlpRuleResult -eq "Blocked" -or $auditData.DlpRuleResult -eq "NotifyUser") { $true } else { $false }
                    RawAuditData      = $event.AuditData
                })
            }

            Write-Status "  Retrieved $($allEvents.Count) events so far..." "INFO"
            $retryCount = 0

        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Status "Max retries reached during audit log query: $($_.Exception.Message)" "WARN"
                break
            }
            Write-Status "Retry $retryCount/$maxRetries after error: $($_.Exception.Message)" "WARN"
            Start-Sleep -Seconds 5
        }

    } while ($results.Count -eq $pageSize)

    Write-Status "Total DLP events retrieved: $($allEvents.Count)" "OK"
    return $allEvents
}

function Write-SummaryReport {
    param(
        [object[]]$Events,
        [object[]]$Policies,
        [DateTime]$StartDate,
        [DateTime]$EndDate
    )

    $separator = "=" * 60

    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  PURVIEW DLP REPORT SUMMARY" -ForegroundColor Cyan
    Write-Host "  Period: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ""

    # Policy status
    Write-Host "[ DLP POLICIES ]" -ForegroundColor Yellow
    $enabledCount = ($Policies | Where-Object { $_.Mode -eq "Enable" }).Count
    $disabledCount = ($Policies | Where-Object { $_.Mode -ne "Enable" }).Count
    Write-Host "  Total policies: $($Policies.Count) | Enabled: $enabledCount | Simulation/Disabled: $disabledCount"
    Write-Host ""

    if ($Policies.Count -gt 0) {
        $Policies | Sort-Object Name | Select-Object Name,
            @{N="Status"; E={ if ($_.Mode -eq "Enable") { "ACTIVE" } else { "SIMULATION/OFF" } }},
            CreatedBy, WhenCreated |
            Format-Table -AutoSize
    }

    if ($Events.Count -eq 0) {
        Write-Host "[ No DLP events found in the selected period ]" -ForegroundColor Yellow
        return
    }

    # Event summary
    Write-Host "[ DLP EVENT SUMMARY ]" -ForegroundColor Yellow
    Write-Host "  Total match events: $($Events.Count)"

    $blocked = ($Events | Where-Object { $_.Action -eq "Blocked" }).Count
    $notified = ($Events | Where-Object { $_.Action -eq "NotifyUser" }).Count
    $override = ($Events | Where-Object { $_.Action -eq "Override" }).Count
    $audit = ($Events.Count - $blocked - $notified - $override)

    Write-Host "  Actions — Blocked: $blocked | User Notified: $notified | Override allowed: $override | Audit only: $audit"
    Write-Host ""

    # Top policies triggered
    Write-Host "[ TOP TRIGGERED POLICIES ]" -ForegroundColor Yellow
    $Events | Group-Object PolicyName | Sort-Object Count -Descending | Select-Object -First 10 |
        Select-Object @{N="Policy"; E={$_.Name}}, Count |
        Format-Table -AutoSize

    # Top rules triggered
    Write-Host "[ TOP TRIGGERED RULES ]" -ForegroundColor Yellow
    $Events | Group-Object RuleName | Sort-Object Count -Descending | Select-Object -First 10 |
        Select-Object @{N="Rule"; E={$_.Name}}, Count |
        Format-Table -AutoSize

    # Top users
    Write-Host "[ TOP USERS WITH POLICY MATCHES ]" -ForegroundColor Yellow
    $Events | Group-Object User | Sort-Object Count -Descending | Select-Object -First 15 |
        Select-Object @{N="User"; E={$_.Name}}, Count |
        Format-Table -AutoSize

    # Sensitive info types
    Write-Host "[ SENSITIVE INFO TYPES DETECTED ]" -ForegroundColor Yellow
    $sitBreakdown = [System.Collections.Generic.Dictionary[string,int]]::new()
    foreach ($event in $Events) {
        if ([string]::IsNullOrEmpty($event.SensitiveInfoTypes)) { continue }
        foreach ($sit in $event.SensitiveInfoTypes -split "; ") {
            if ($sitBreakdown.ContainsKey($sit)) { $sitBreakdown[$sit]++ }
            else { $sitBreakdown[$sit] = 1 }
        }
    }
    $sitBreakdown.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 |
        Select-Object @{N="Sensitive Info Type"; E={$_.Key}}, @{N="Occurrences"; E={$_.Value}} |
        Format-Table -AutoSize

    # Workload breakdown
    Write-Host "[ EVENTS BY WORKLOAD ]" -ForegroundColor Yellow
    $Events | Group-Object Workload | Sort-Object Count -Descending |
        Select-Object @{N="Workload"; E={$_.Name}}, Count |
        Format-Table -AutoSize
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting Purview DLP Report..." "INFO"

# Preflight — check ExchangeOnlineManagement module
if (-not (Get-Module -Name ExchangeOnlineManagement -ListAvailable)) {
    Write-Status "ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement" "ERROR"
    exit 1
}

# Preflight — ensure output path exists
if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path does not exist: $OutputPath — creating..." "WARN"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Connect to Security & Compliance Center
Write-Status "Connecting to Security & Compliance Center..." "INFO"
try {
    Connect-IPPSSession -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Status "Connected to S&C PowerShell" "OK"
}
catch {
    Write-Status "Failed to connect to Security & Compliance Center: $($_.Exception.Message)" "ERROR"
    Write-Status "Ensure ExchangeOnlineManagement is installed and you have Compliance Admin rights" "WARN"
    exit 1
}

# Date range
$endDate   = Get-Date
$startDate = $endDate.AddDays(-$Days)

# Retrieve DLP policies
$dlpPolicies = Get-DLPPolicies

# Retrieve DLP audit events
$dlpEvents = Get-DLPAuditEvents -StartDate $startDate -EndDate $endDate `
    -UserFilter $UserPrincipalName -PolicyFilter $PolicyName

# Display summary report
Write-SummaryReport -Events $dlpEvents -Policies $dlpPolicies `
    -StartDate $startDate -EndDate $endDate

# Export: policy list
$policyFile = Join-Path $OutputPath "DLP-Policies-$(Get-Date -Format 'yyyyMMdd').csv"
if ($dlpPolicies.Count -gt 0) {
    $dlpPolicies | Select-Object Name, Mode, CreatedBy, WhenCreated, WhenChanged,
        @{N="WorkloadsApplied"; E={ $_.ExchangeLocation.Count + $_.SharePointLocation.Count + $_.OneDriveLocation.Count }} |
        Export-Csv -Path $policyFile -NoTypeInformation -Encoding UTF8
    Write-Status "Policy list exported to: $policyFile" "OK"
}

# Export: incident summary
if ($dlpEvents.Count -gt 0) {
    $summaryFile = Join-Path $OutputPath "DLP-Incidents-$(Get-Date -Format 'yyyyMMdd').csv"
    $dlpEvents | Select-Object TimeStamp, User, Workload, PolicyName, RuleName,
        Action, SensitiveInfoTypes, MatchCount, Location, FileName, AlertTriggered |
        Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8
    Write-Status "Incident summary exported to: $summaryFile" "OK"

    # Export raw events if requested
    if ($ExportAll) {
        $rawFile = Join-Path $OutputPath "DLP-RawAudit-$(Get-Date -Format 'yyyyMMdd').csv"
        $dlpEvents | Select-Object TimeStamp, User, Workload, PolicyName, RuleName, Action, RawAuditData |
            Export-Csv -Path $rawFile -NoTypeInformation -Encoding UTF8
        Write-Status "Raw audit data exported to: $rawFile" "OK"
    }
}

Write-Status "DLP report complete. Files written to: $OutputPath" "OK"
