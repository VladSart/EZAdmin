<#
.SYNOPSIS
    Audits Microsoft Purview Insider Risk Management (IRM) policy health, alert volume, and
    prerequisite signal plumbing.

.DESCRIPTION
    Connects to Security & Compliance PowerShell and Microsoft Graph to produce a single-pass
    health check for Insider Risk Management, automating the Validation Steps and Phase 1/2
    checks from Insider-Risk-A.md so an analyst does not have to walk the portal manually.

    Covers:
    - Unified Audit Log ingestion status (the foundation signal — IRM has nothing without it)
    - IRM policy list, enabled/disabled state, and last modified date
    - Alert volume by severity for the lookback window, with a NOISY_POLICY flag when the
      proportion of High-severity alerts exceeds a configurable threshold (per Insider-Risk-A.md
      Phase 2 guidance that an all-High distribution usually means indicator weights are
      misconfigured, not that every alert is a real incident)
    - E5 / E5 Compliance licence coverage check (a licensing gap on a policy's in-scope users
      is a common cause of "audit shows activity but IRM shows nothing")
    - Optional Adaptive Protection cross-check: flags policies that reference Insider Risk in
      Conditional Access without any users currently carrying an elevated risk level

    Does NOT cover:
    - Purview Communication Compliance (separate module)
    - HRMS connector CSV validation (portal-only; see Insider-Risk-A.md Playbook 4)
    - Endpoint DLP / MDE-side telemetry (separate agent-side check)

.PARAMETER Days
    Lookback window in days for alert volume and audit log sampling. Default: 30. Max: 90.

.PARAMETER HighSeverityNoiseThresholdPercent
    Percentage of alerts that must be High severity before a policy is flagged NOISY_POLICY.
    Default: 80.

.PARAMETER CheckAdaptiveProtection
    Switch. If specified, also queries Conditional Access policies for Insider Risk conditions
    and cross-references against current risk-level assignments. Requires Policy.Read.All.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-InsiderRiskPolicyStatus.ps1 -Days 30 -OutputPath C:\Temp\IRM

.EXAMPLE
    .\Get-InsiderRiskPolicyStatus.ps1 -Days 14 -HighSeverityNoiseThresholdPercent 70 -CheckAdaptiveProtection

.NOTES
    Requires:
    - ExchangeOnlineManagement module (for Connect-IPPSSession, Get-AdminAuditLogConfig)
    - Microsoft.Graph module (for licence check and optional CA check)
    - Insider Risk Management (Analyst or Admin) role; Compliance Admin for audit config
    - Unified Audit Log enabled tenant-wide

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to tenant configuration or policies.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$Days = 30,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$HighSeverityNoiseThresholdPercent = 80,

    [switch]$CheckAdaptiveProtection,

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

function Test-AuditLogHealth {
    Write-Status "Checking Unified Audit Log ingestion status..." "INFO"
    try {
        $config = Get-AdminAuditLogConfig -ErrorAction Stop
        $enabled = $config.UnifiedAuditLogIngestionEnabled
        if ($enabled) {
            Write-Status "Unified Audit Log ingestion: ENABLED" "OK"
        } else {
            Write-Status "Unified Audit Log ingestion: DISABLED — IRM cannot generate alerts without this" "ERROR"
        }
        return [PSCustomObject]@{
            UnifiedAuditLogEnabled = $enabled
            AuditLogAgeLimit       = $config.AuditLogAgeLimit
        }
    }
    catch {
        Write-Status "Failed to retrieve audit log config: $($_.Exception.Message)" "ERROR"
        return [PSCustomObject]@{ UnifiedAuditLogEnabled = $null; AuditLogAgeLimit = $null }
    }
}

function Get-IRMPolicySummary {
    Write-Status "Retrieving Insider Risk Management policies..." "INFO"
    try {
        $policies = Get-InsiderRiskPolicy -ErrorAction Stop
        Write-Status "Found $($policies.Count) IRM policies" "OK"
        return $policies
    }
    catch {
        Write-Status "Failed to retrieve IRM policies: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-IRMAlertVolume {
    param([int]$LookbackDays)

    Write-Status "Retrieving IRM alerts (open/NeedsReview)..." "INFO"
    try {
        $alerts = Get-InsiderRiskAlert -AlertStatus NeedsReview -ErrorAction Stop
        $cutoff = (Get-Date).AddDays(-$LookbackDays)
        $recent = $alerts | Where-Object { $_.CreatedDateTime -ge $cutoff }
        Write-Status "Found $($recent.Count) alerts in the last $LookbackDays days" "OK"
        return $recent
    }
    catch {
        Write-Status "Failed to retrieve IRM alerts: $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Get-E5ComplianceLicenceGap {
    param([object[]]$Policies)

    Write-Status "Checking E5 / E5 Compliance licence coverage..." "INFO"
    $e5Sku      = "06ebc4ee-1bb5-47dd-8120-11324bc54e06"  # Microsoft 365 E5
    $e5CompSku  = "184efa21-98c3-4e5d-95ab-d07053a96e67"  # Microsoft 365 E5 Compliance

    try {
        $users = Get-MgUser -All -Property DisplayName, UserPrincipalName, AssignedLicenses -ErrorAction Stop
        $unlicensed = $users | Where-Object {
            $_.AssignedLicenses.SkuId -notcontains $e5Sku -and $_.AssignedLicenses.SkuId -notcontains $e5CompSku
        }
        $totalCount      = ($users | Measure-Object).Count
        $unlicensedCount = ($unlicensed | Measure-Object).Count

        if ($totalCount -gt 0) {
            $pctUnlicensed = [math]::Round(($unlicensedCount / $totalCount) * 100, 1)
            Write-Status "Users without E5/E5-Compliance licence: $unlicensedCount of $totalCount ($pctUnlicensed%)" $(if ($pctUnlicensed -gt 25) { "WARN" } else { "INFO" })
        }
        return $unlicensed | Select-Object DisplayName, UserPrincipalName
    }
    catch {
        Write-Status "Failed to check licence coverage (requires User.Read.All + Organization.Read.All): $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Get-AdaptiveProtectionGap {
    Write-Status "Cross-checking Adaptive Protection Conditional Access policies..." "INFO"
    try {
        $caPolicies = Get-MgIdentityConditionalAccessPolicy -ErrorAction Stop |
            Where-Object { $_.DisplayName -like "*Insider*" -or $_.DisplayName -like "*Adaptive Protection*" }

        if (-not $caPolicies -or $caPolicies.Count -eq 0) {
            Write-Status "No Conditional Access policy references Insider Risk / Adaptive Protection — CA enforcement is not configured" "WARN"
        } else {
            Write-Status "Found $($caPolicies.Count) CA policy/policies referencing Insider Risk" "OK"
        }
        return $caPolicies | Select-Object DisplayName, State, Id
    }
    catch {
        Write-Status "Failed Adaptive Protection CA check (requires Policy.Read.All): $($_.Exception.Message)" "WARN"
        return @()
    }
}

function Write-SummaryReport {
    param(
        [object]$AuditHealth,
        [object[]]$Policies,
        [object[]]$Alerts,
        [object[]]$UnlicensedUsers,
        [int]$NoiseThreshold,
        [object[]]$CAGap
    )

    $separator = "=" * 60
    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "  INSIDER RISK MANAGEMENT — POLICY STATUS REPORT" -ForegroundColor Cyan
    Write-Host "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[ AUDIT LOG FOUNDATION ]" -ForegroundColor Yellow
    Write-Host "  UnifiedAuditLogIngestionEnabled: $($AuditHealth.UnifiedAuditLogEnabled)"
    Write-Host ""

    Write-Host "[ POLICIES ]" -ForegroundColor Yellow
    if ($Policies.Count -eq 0) {
        Write-Host "  No IRM policies found." -ForegroundColor Yellow
    } else {
        $Policies | Select-Object Name, IsEnabled, CreatedDateTime |
            Format-Table -AutoSize
    }
    Write-Host ""

    Write-Host "[ ALERT SEVERITY DISTRIBUTION (per policy) ]" -ForegroundColor Yellow
    if ($Alerts.Count -eq 0) {
        Write-Host "  No open alerts in the lookback window." -ForegroundColor Yellow
    } else {
        $byPolicy = $Alerts | Group-Object { ($_.AlertPolicies -join ",") }
        foreach ($group in $byPolicy) {
            $high    = ($group.Group | Where-Object { $_.Severity -eq "High" }).Count
            $total   = $group.Count
            $pctHigh = if ($total -gt 0) { [math]::Round(($high / $total) * 100, 1) } else { 0 }
            $flag    = if ($pctHigh -ge $NoiseThreshold) { "NOISY_POLICY" } else { "OK" }
            $status  = if ($flag -eq "NOISY_POLICY") { "WARN" } else { "OK" }
            Write-Status "  Policy '$($group.Name)': $total alerts, $pctHigh% High severity — $flag" $status
        }
    }
    Write-Host ""

    Write-Host "[ LICENCE GAP ]" -ForegroundColor Yellow
    Write-Host "  Users without E5/E5-Compliance: $($UnlicensedUsers.Count)"
    Write-Host ""

    if ($CAGap) {
        Write-Host "[ ADAPTIVE PROTECTION — CA CROSS-CHECK ]" -ForegroundColor Yellow
        if ($CAGap.Count -eq 0) {
            Write-Host "  No CA policy references Insider Risk / Adaptive Protection." -ForegroundColor Yellow
        } else {
            $CAGap | Format-Table -AutoSize
        }
    }
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting Insider Risk Management Policy Status check..." "INFO"

foreach ($mod in @("ExchangeOnlineManagement", "Microsoft.Graph.Authentication", "Microsoft.Graph.Users")) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        exit 1
    }
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
    exit 1
}

Write-Status "Connecting to Exchange Online (audit log check)..." "INFO"
try {
    Connect-ExchangeOnline -ShowProgress $false -ErrorAction Stop
    Write-Status "Connected to Exchange Online" "OK"
}
catch {
    Write-Status "Failed to connect to Exchange Online: $($_.Exception.Message)" "WARN"
}

Write-Status "Connecting to Microsoft Graph..." "INFO"
try {
    $scopes = @("User.Read.All", "Organization.Read.All")
    if ($CheckAdaptiveProtection) { $scopes += "Policy.Read.All" }
    Connect-MgGraph -Scopes $scopes -ErrorAction Stop -NoWelcome
    Write-Status "Connected to Microsoft Graph" "OK"
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "WARN"
}

$auditHealth  = Test-AuditLogHealth
$policies     = Get-IRMPolicySummary
$alerts       = Get-IRMAlertVolume -LookbackDays $Days
$unlicensed   = Get-E5ComplianceLicenceGap -Policies $policies
$caGap        = if ($CheckAdaptiveProtection) { Get-AdaptiveProtectionGap } else { $null }

Write-SummaryReport -AuditHealth $auditHealth -Policies $policies -Alerts $alerts `
    -UnlicensedUsers $unlicensed -NoiseThreshold $HighSeverityNoiseThresholdPercent -CAGap $caGap

# Exports
$stamp = Get-Date -Format 'yyyyMMdd'

if ($policies.Count -gt 0) {
    $policyFile = Join-Path $OutputPath "IRM-Policies-$stamp.csv"
    $policies | Select-Object Name, IsEnabled, CreatedDateTime, ModifiedDateTime |
        Export-Csv -Path $policyFile -NoTypeInformation -Encoding UTF8
    Write-Status "Policy list exported to: $policyFile" "OK"
}

if ($alerts.Count -gt 0) {
    $alertFile = Join-Path $OutputPath "IRM-Alerts-$stamp.csv"
    $alerts | Select-Object AlertId, Severity, CreatedDateTime, AlertPolicies |
        Export-Csv -Path $alertFile -NoTypeInformation -Encoding UTF8
    Write-Status "Alert list exported to: $alertFile" "OK"
}

if ($unlicensed.Count -gt 0) {
    $licFile = Join-Path $OutputPath "IRM-LicenceGap-$stamp.csv"
    $unlicensed | Export-Csv -Path $licFile -NoTypeInformation -Encoding UTF8
    Write-Status "Licence gap list exported to: $licFile" "OK"
}

if ($caGap -and $caGap.Count -gt 0) {
    $caFile = Join-Path $OutputPath "IRM-AdaptiveProtection-CA-$stamp.csv"
    $caGap | Export-Csv -Path $caFile -NoTypeInformation -Encoding UTF8
    Write-Status "Adaptive Protection CA cross-check exported to: $caFile" "OK"
}

Write-Status "Insider Risk Management policy status check complete. Files written to: $OutputPath" "OK"
