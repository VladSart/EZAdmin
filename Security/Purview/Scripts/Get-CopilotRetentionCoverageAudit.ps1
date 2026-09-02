<#
.SYNOPSIS
    Audits Microsoft Purview retention and collection policy coverage for Copilot and AI app locations.

.DESCRIPTION
    Companion script to Security/Purview/CopilotRetentionRecommendations-A.md and -B.md.

    Microsoft 365 Roadmap ID 561209 adds a Purview-native insights/recommendations layer that
    analyzes Copilot and AI app usage and recommends retention policies. That recommendation engine
    has NO PowerShell or Graph read surface as of this writing — there is no cmdlet to list, export,
    or accept a recommendation. This script does NOT attempt to read recommendations.

    Instead, it audits the readiness signals a recommendation depends on and that this runbook's
    Diagnosis/Validation steps reference directly:
      - Every retention policy and whether it targets the Copilot/AI-app location
      - Every collection policy (required for Enterprise AI apps / Other AI apps visibility; NOT
        required for first-party Microsoft Copilot experiences, which are captured automatically)
      - Retention compliance rules tied to those policies (duration, retain vs. delete action)
      - A plain-language gap flag: retention policy exists but no matching collection policy found
        for a non-first-party AI app category (the single most common reason a recommendation or an
        existing policy appears to have "no effect")

    Requires: Security & Compliance PowerShell (Connect-IPPSSession) with Data Lifecycle Management /
    Compliance Administrator read rights.

.PARAMETER AdminUPN
    UPN to use for Connect-IPPSSession. If omitted, assumes an existing IPPS session is present.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to the current user's temp folder.

.EXAMPLE
    .\Get-CopilotRetentionCoverageAudit.ps1 -AdminUPN admin@contoso.com

    Connects, audits AI-app retention/collection policy coverage, and exports a CSV report.

.NOTES
    Read-only. Makes no configuration changes. Cannot read Roadmap 561209 recommendation state — see
    .DESCRIPTION. Requires the ExchangeOnlineManagement module.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminUPN,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = (Join-Path $env:TEMP "CopilotRetentionCoverageAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Copilot/AI app retention coverage audit" "INFO"

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Status "ExchangeOnlineManagement module not found. Install with: Install-Module ExchangeOnlineManagement" "ERROR"
    throw "Required module missing."
}

try {
    $null = Get-RetentionCompliancePolicy -ErrorAction Stop -ResultSize 1
    Write-Status "Existing IPPS session detected." "OK"
}
catch {
    if ([string]::IsNullOrWhiteSpace($AdminUPN)) {
        Write-Status "No active session and -AdminUPN not supplied. Connecting interactively." "WARN"
        Connect-IPPSSession
    }
    else {
        Write-Status "Connecting to Security & Compliance PowerShell as $AdminUPN" "INFO"
        Connect-IPPSSession -UserPrincipalName $AdminUPN
    }
}

# ---------------------------------------------------------------------------
# Detect: retention policies touching Copilot/AI-app locations
# ---------------------------------------------------------------------------
Write-Status "Enumerating retention compliance policies" "INFO"
$allPolicies = Get-RetentionCompliancePolicy -ErrorAction SilentlyContinue
$aiPolicies = $allPolicies | Where-Object {
    $_.Copilot -or ($_.ExchangeLocation -match "AI|Copilot") -or ($_.Name -match "Copilot|AI app|AI App")
}
Write-Status "Found $($allPolicies.Count) total retention policies; $($aiPolicies.Count) reference Copilot/AI-app scope by name or property." "INFO"

# ---------------------------------------------------------------------------
# Detect: collection policies (Enterprise AI apps / Other AI apps capture gate)
# ---------------------------------------------------------------------------
Write-Status "Enumerating collection policies (required for non-first-party AI app capture)" "INFO"
$collectionPolicies = @()
try {
    $collectionPolicies = Get-CollectionPolicy -ErrorAction Stop
    Write-Status "Found $($collectionPolicies.Count) collection policies." "INFO"
}
catch {
    Write-Status "Get-CollectionPolicy not available or returned no results in this tenant/role context. Enterprise/Other AI app coverage cannot be confirmed via PowerShell here — verify in the Purview portal." "WARN"
}

# ---------------------------------------------------------------------------
# Detect: retention compliance rules (duration / retain vs delete) per policy
# ---------------------------------------------------------------------------
Write-Status "Enumerating retention compliance rules for AI-app-scoped policies" "INFO"
$ruleReport = foreach ($policy in $aiPolicies) {
    $rules = Get-RetentionComplianceRule -Policy $policy.Name -ErrorAction SilentlyContinue
    foreach ($rule in $rules) {
        [PSCustomObject]@{
            PolicyName       = $policy.Name
            PolicyEnabled    = $policy.Enabled
            RuleName         = $rule.Name
            RetentionDuration = $rule.RetentionDuration
            Action           = $rule.RetentionComplianceAction
            ExchangeLocation = $policy.ExchangeLocation -join ";"
        }
    }
}

# ---------------------------------------------------------------------------
# Gap analysis: AI-app-named retention policy with no corresponding collection policy
# ---------------------------------------------------------------------------
Write-Status "Cross-checking for retention-without-collection gaps" "INFO"
$gapFindings = @()
foreach ($policy in $aiPolicies) {
    $hasFirstPartyCopilot = $policy.Name -match "Copilot experience|Microsoft Copilot" -or $policy.Copilot
    if (-not $hasFirstPartyCopilot -and $collectionPolicies.Count -ge 0) {
        $matchingCollection = $collectionPolicies | Where-Object { $_.Enabled -and $policy.Name -match [regex]::Escape($_.Name) }
        if (-not $matchingCollection) {
            $gapFindings += [PSCustomObject]@{
                RetentionPolicyName = $policy.Name
                PolicyEnabled       = $policy.Enabled
                Finding             = "No confidently-matched enabled collection policy found by name correlation. If this policy targets Enterprise AI apps or Other AI apps (not first-party Copilot), verify a collection policy is configured and enabled in the Purview portal -- name-based correlation in this script is best-effort only."
            }
        }
    }
}

if ($gapFindings.Count -gt 0) {
    Write-Status "$($gapFindings.Count) potential retention-without-collection gap(s) found -- verify manually in the portal." "WARN"
}
else {
    Write-Status "No obvious retention-without-collection gaps found via name correlation (best-effort check only)." "OK"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "=== Summary ===" "INFO"
Write-Host ""
Write-Host "AI-app-relevant retention policies:" -ForegroundColor Cyan
$aiPolicies | Select-Object Name, Enabled, Copilot | Format-Table -AutoSize

Write-Host "Collection policies:" -ForegroundColor Cyan
if ($collectionPolicies.Count -gt 0) {
    $collectionPolicies | Select-Object Name, Enabled, Workload | Format-Table -AutoSize
}
else {
    Write-Host "  (none found / not readable in this context — confirm in portal)" -ForegroundColor Yellow
}

Write-Host "Retention rules for AI-app-scoped policies:" -ForegroundColor Cyan
$ruleReport | Format-Table -AutoSize

if ($gapFindings.Count -gt 0) {
    Write-Host "Potential coverage gaps (best-effort, verify manually):" -ForegroundColor Yellow
    $gapFindings | Format-Table -AutoSize
}

$exportData = @()
$exportData += $aiPolicies | Select-Object @{N = "Type"; E = { "RetentionPolicy" } }, Name, Enabled, Copilot
$exportData += $ruleReport | Select-Object @{N = "Type"; E = { "RetentionRule" } }, PolicyName, RetentionDuration, Action
$exportData += $gapFindings | Select-Object @{N = "Type"; E = { "GapFinding" } }, RetentionPolicyName, Finding

$exportData | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" "OK"

Write-Host ""
Write-Status "REMINDER: Roadmap 561209's recommendation engine itself has no PowerShell/Graph surface." "WARN"
Write-Status "This script audits readiness signals only -- capture actual recommendations from the Purview portal manually." "WARN"
