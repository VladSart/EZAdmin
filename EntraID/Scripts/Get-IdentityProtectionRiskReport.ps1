<#
.SYNOPSIS
    Tenant-wide Identity Protection risk report — risky users, active detections,
    and risk-based Conditional Access enforcement coverage.

.DESCRIPTION
    Connects to Microsoft Graph and builds a fleet-level view of Identity
    Protection state so an operator can triage risk tickets and spot systemic
    gaps in one pass, instead of checking one user at a time:
    - Lists all currently at-risk users (RiskState: atRisk / confirmedCompromised)
      with their risk level and the risk event types behind the flag.
    - Flags HIGH_CONFIDENCE detections (leakedCredentials, passwordSpray) — these
      should be treated as confirmed compromise, not "maybe," per
      IdentityProtection-B.md.
    - Cross-checks whether each at-risk user actually holds an Entra ID P2 (or
      equivalent) license — without it, risk-based Conditional Access policies
      cannot enforce even though detections still populate.
    - Reports whether any risk-based Conditional Access policy exists tenant-wide
      and whether it is enabled, report-only, or disabled — a report-only policy
      on a real risk event means detections are being logged but nothing is
      actually blocking sign-in.

    This is a fleet-level triage tool: read-only, makes no changes to users,
    risk states, or policies. Exports full results to CSV and prints a
    colour-coded console summary.

    Does NOT cover:
    - Per-sign-in Conditional Access evaluation detail (AppliedConditionalAccessPolicies)
      for a specific event — see EntraID/Troubleshooting/IdentityProtection-A.md
      Validation Steps, run per-user/per-session
    - Remediation actions (password reset, session revoke, dismiss) — see
      IdentityProtection-B.md Fix 1-5, which are deliberately left as manual/
      reviewed actions rather than automated by this script
    - CAE-driven session interruption correlation — see
      EntraID/Scripts/Get-CAESessionEvents.ps1 and CAE-B.md

.PARAMETER MinRiskLevel
    Minimum risk level to include in the at-risk user report. One of: low,
    medium, high. Default: medium.

.PARAMETER IncludeDismissed
    Include users whose risk has already been dismissed or remediated, for a
    historical view rather than just active risk. Default: off (active risk only).

.PARAMETER OutputPath
    Path for the CSV export. Default: .\IdentityProtection-Risk-<timestamp>.csv

.EXAMPLE
    .\Get-IdentityProtectionRiskReport.ps1

    Reports all currently at-risk users at medium risk level or above, with
    license and CA policy enforcement context.

.EXAMPLE
    .\Get-IdentityProtectionRiskReport.ps1 -MinRiskLevel low -IncludeDismissed

    Broadest view — includes low-risk and historical dismissed/remediated users,
    useful for a monthly Identity Protection posture review.

.NOTES
    Requires: Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Users,
              Microsoft.Graph.Identity.DirectoryManagement PowerShell SDK modules
    Scopes needed: IdentityRiskyUser.Read.All, Policy.Read.All, User.Read.All
    Run As: An account with Security Reader or Global Reader role — does not
            require write permissions
    Safe: Read-only — no users, risk states, or policies are changed
    Cross-references: EntraID/Troubleshooting/IdentityProtection-B.md (Triage,
                       Diagnosis & Validation Flow, Fix 1-5) and
                       IdentityProtection-A.md

    Known limitation: license coverage check queries per flagged user (not the
    whole tenant) to keep runtime reasonable — for a full tenant P2 coverage
    audit, cross-reference against a licensing report rather than this script.
#>

[CmdletBinding()]
param(
    [ValidateSet("low", "medium", "high")]
    [string]$MinRiskLevel = "medium",

    [switch]$IncludeDismissed,

    [string]$OutputPath = ".\IdentityProtection-Risk-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

$riskRank = @{ "low" = 0; "medium" = 1; "high" = 2 }
$highConfidenceTypes = @("leakedCredentials", "passwordSpray")

# ---- Preflight ----
Write-Status "Checking Microsoft.Graph.Identity.SignIns module..." "INFO"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.SignIns)) {
    Write-Status "Microsoft.Graph.Identity.SignIns module not found. Install with: Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser" "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Graph. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "IdentityRiskyUser.Read.All", "Policy.Read.All", "User.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) [tenant: $($context.TenantId)]" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

$results = [System.Collections.Generic.List[object]]::new()

# ---- Detect: risky users ----
Write-Status "Retrieving risky users (this may take a moment on large tenants)..." "INFO"
$riskyUsers = @()
try {
    $filter = if ($IncludeDismissed) { $null } else { "riskState eq 'atRisk' or riskState eq 'confirmedCompromised'" }
    if ($filter) {
        $riskyUsers = Get-MgRiskyUser -Filter $filter -All -ErrorAction Stop
    }
    else {
        $riskyUsers = Get-MgRiskyUser -All -ErrorAction Stop
    }
    Write-Status "Retrieved $($riskyUsers.Count) risky user record(s)." "OK"
}
catch {
    Write-Status "Failed to retrieve risky users: $($_.Exception.Message)" "ERROR"
}

$riskyUsers = $riskyUsers | Where-Object { $riskRank[$_.RiskLevel] -ge $riskRank[$MinRiskLevel] }
Write-Status "$($riskyUsers.Count) user(s) at or above '$MinRiskLevel' risk level." "INFO"

# ---- Detect: risk-based Conditional Access policy coverage (tenant-wide, once) ----
Write-Status "Checking for risk-based Conditional Access policies..." "INFO"
$riskPolicies = @()
try {
    $allPolicies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    $riskPolicies = $allPolicies | Where-Object {
        $_.Conditions.UserRiskLevels.Count -gt 0 -or $_.Conditions.SignInRiskLevels.Count -gt 0
    }
    if ($riskPolicies.Count -eq 0) {
        Write-Status "NO risk-based Conditional Access policies found tenant-wide. Detections will log but nothing will enforce." "ERROR"
    }
    else {
        foreach ($p in $riskPolicies) {
            $stateStatus = switch ($p.State) {
                "enabled" { "OK" }
                "enabledForReportingButNotEnforced" { "WARN" }
                default { "ERROR" }
            }
            Write-Status "Risk policy '$($p.DisplayName)': state=$($p.State)" $stateStatus
        }
    }
}
catch {
    Write-Status "Failed to retrieve Conditional Access policies: $($_.Exception.Message)" "WARN"
}

# ---- Detect: per-user license + detection detail ----
foreach ($ru in $riskyUsers) {
    $detections = @()
    try {
        $detections = Get-MgRiskDetection -Filter "userPrincipalName eq '$($ru.UserPrincipalName)'" -Top 10 -ErrorAction Stop
    }
    catch {
        Write-Status "Could not retrieve detections for $($ru.UserPrincipalName): $($_.Exception.Message)" "WARN"
    }

    $eventTypes = ($detections | Select-Object -ExpandProperty RiskEventType -Unique) -join ";"
    $hasHighConfidence = ($detections | Where-Object { $highConfidenceTypes -contains $_.RiskEventType }).Count -gt 0

    $hasP2 = $false
    try {
        $licenses = Get-MgUserLicenseDetail -UserId $ru.UserPrincipalName -ErrorAction Stop
        $hasP2 = [bool]($licenses | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM_P2|SPE_E5|M365_E5|MICROSOFT_ENTRA_ID_GOVERNANCE" })
    }
    catch {
        Write-Status "Could not retrieve license detail for $($ru.UserPrincipalName): $($_.Exception.Message)" "WARN"
    }

    $enforcementGap = ($riskPolicies.Count -eq 0) -or (-not $hasP2) -or (($riskPolicies | Where-Object { $_.State -eq "enabled" }).Count -eq 0)

    $results.Add([PSCustomObject]@{
        UserPrincipalName = $ru.UserPrincipalName
        RiskLevel         = $ru.RiskLevel
        RiskState         = $ru.RiskState
        RiskLastUpdated   = $ru.RiskLastUpdatedDateTime
        EventTypes        = $eventTypes
        HighConfidence    = $hasHighConfidence
        P2Licensed        = $hasP2
        RiskPolicyEnabled = ($riskPolicies | Where-Object { $_.State -eq "enabled" }).Count -gt 0
        EnforcementGap    = $enforcementGap
    })
}

# ---- Report ----
Write-Host ""
Write-Host "=== Identity Protection Risk Summary ===" -ForegroundColor Cyan
if ($results.Count -eq 0) {
    Write-Status "No users found at or above '$MinRiskLevel' risk level." "OK"
}
else {
    $highConfidenceCount = ($results | Where-Object { $_.HighConfidence }).Count
    $gapCount = ($results | Where-Object { $_.EnforcementGap }).Count
    Write-Status "$($results.Count) at-risk user(s) reported." "INFO"
    Write-Status "$highConfidenceCount user(s) have HIGH-CONFIDENCE detections (leakedCredentials/passwordSpray) — treat as confirmed compromise." $(if ($highConfidenceCount -gt 0) { "ERROR" } else { "OK" })
    Write-Status "$gapCount user(s) have an enforcement gap (missing P2 license and/or no enabled risk policy)." $(if ($gapCount -gt 0) { "WARN" } else { "OK" })
    Write-Host ""
    $results | Sort-Object HighConfidence -Descending | Format-Table UserPrincipalName, RiskLevel, RiskState, HighConfidence, P2Licensed, EnforcementGap -AutoSize
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to $OutputPath" "OK"
