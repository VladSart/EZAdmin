<#
.SYNOPSIS
    Read-only readiness/context audit for Microsoft Purview DLP Alert Auto-Resolution & Tagging
    rules (Microsoft 365 Roadmap ID 568371, Preview Aug 2026 / GA Sept 2026).

.DESCRIPTION
    Auto-resolution and tagging rules are configured entirely in the Purview portal
    (Data Loss Prevention > Alerts > Alert rules) and have no documented PowerShell or
    Microsoft Graph read/write surface as of this writing. This script does NOT read,
    create, or modify those rules. Instead it audits the adjacent, scriptable signals an
    engineer needs before recommending or troubleshooting rule adoption:
      - DLP licensing floor (single-event vs. aggregate/threshold alert eligibility)
      - Active DLP policies and whether their rules are configured to generate alerts
      - Recent alert volume and status, to identify high-volume/repetitive candidates
      - RBAC membership for the roles that gate rule authorship ("Manage alerts" +
        DLP Compliance Management / View-Only DLP Compliance Management)
    Output is exported to CSV files plus a console summary. Prints an explicit portal-only
    checklist for the rule-engine state itself, since it cannot be queried programmatically.

.PARAMETER OutputPath
    Directory to write CSV exports to. Defaults to the current directory.

.PARAMETER LookbackDays
    Number of days of DLP alert history to pull. Defaults to 30.

.EXAMPLE
    .\Get-DLPAlertOperationsAudit.ps1 -OutputPath C:\Audits -LookbackDays 14

.NOTES
    Requires: Connect-IPPSSession (Security & Compliance PowerShell) and Microsoft.Graph
    (Get-MgSubscribedSku) to be connected before running.
    Safe/read-only: issues no writes, creates no rules, resolves no alerts.
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
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting DLP Alert Operations audit (lookback: $LookbackDays days)"

$commandsNeeded = @("Get-DlpCompliancePolicy", "Get-DlpComplianceRule", "Get-ProtectionAlert", "Get-RoleGroupMember")
$missing = $commandsNeeded | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing) {
    Write-Status "Missing cmdlets: $($missing -join ', '). Run Connect-IPPSSession first." "ERROR"
    throw "Not connected to Security & Compliance PowerShell."
}

$graphAvailable = [bool](Get-Command Get-MgSubscribedSku -ErrorAction SilentlyContinue)
if (-not $graphAvailable) {
    Write-Status "Get-MgSubscribedSku not available — licensing section will be skipped. Connect-MgGraph to include it." "WARN"
}

# ---------------------------------------------------------------------------
# 1. Licensing floor
# ---------------------------------------------------------------------------
Write-Status "Checking DLP / aggregate-alert licensing signal..."
$licenseResults = @()
if ($graphAvailable) {
    try {
        $skus = Get-MgSubscribedSku
        $dlpSkuPattern   = "SPE_E3|SPE_E5|SPE_F1|EXCHANGESTANDARD|EXCHANGEENTERPRISE|SPB|SMB_BUSINESS_PREMIUM"
        $aggSkuPattern   = "SPE_E5|ENTERPRISEPREMIUM|IDENTITY_THREAT_PROTECTION|M365_E5_SUITE_COMPONENTS|THREAT_INTELLIGENCE"
        foreach ($sku in $skus) {
            $tier = "Other"
            if ($sku.SkuPartNumber -match $aggSkuPattern) { $tier = "Aggregate-alert eligible" }
            elseif ($sku.SkuPartNumber -match $dlpSkuPattern) { $tier = "Single-event DLP only (verify add-ons for aggregate)" }
            $licenseResults += [PSCustomObject]@{
                SkuPartNumber = $sku.SkuPartNumber
                ConsumedUnits = $sku.ConsumedUnits
                PrepaidUnits  = $sku.PrepaidUnits.Enabled
                AlertTier     = $tier
            }
        }
        $aggEligible = $licenseResults | Where-Object { $_.AlertTier -eq "Aggregate-alert eligible" }
        if ($aggEligible) {
            Write-Status "Aggregate/threshold alert licensing confirmed via: $(($aggEligible.SkuPartNumber) -join ', ')" "OK"
        } else {
            Write-Status "No confirmed aggregate-alert SKU found — tenant may be limited to single-event alerts unless an add-on (Defender for O365 Plan 2 / Purview Suite / eDiscovery & Audit) is present" "WARN"
        }
        $licenseResults | Export-Csv -Path (Join-Path $OutputPath "DLPAlertOps_Licensing_$timestamp.csv") -NoTypeInformation
    } catch {
        Write-Status "Licensing check failed: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# 2. DLP policies + alert-generation configuration
# ---------------------------------------------------------------------------
Write-Status "Inventorying DLP policies and rule alert configuration..."
$policies = Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled, Workload
$rules    = Get-DlpComplianceRule | Select-Object Name, Policy, Disabled, GenerateAlert, NotifyUser

$policies | Export-Csv -Path (Join-Path $OutputPath "DLPAlertOps_Policies_$timestamp.csv") -NoTypeInformation
$rules    | Export-Csv -Path (Join-Path $OutputPath "DLPAlertOps_Rules_$timestamp.csv") -NoTypeInformation

$enabledCount = ($policies | Where-Object { $_.Enabled -eq $true }).Count
Write-Status "Found $($policies.Count) DLP policies ($enabledCount enabled)" "OK"

$alertingRules = $rules | Where-Object { $_.GenerateAlert -and -not $_.Disabled }
if ($alertingRules.Count -eq 0) {
    Write-Status "No enabled rules found with GenerateAlert configured — no alert population exists for auto-resolution/tagging to act on yet" "WARN"
} else {
    Write-Status "$($alertingRules.Count) enabled rule(s) generating alerts" "OK"
}

# ---------------------------------------------------------------------------
# 3. Recent alert volume — candidate identification for auto-resolution/tagging rules
# ---------------------------------------------------------------------------
Write-Status "Pulling DLP alert history (last $LookbackDays days)..."
$cutoff = (Get-Date).AddDays(-$LookbackDays)
$alerts = Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt $cutoff } |
    Select-Object Name, Severity, Status, Count, LastUpdatedTime

$alerts | Export-Csv -Path (Join-Path $OutputPath "DLPAlertOps_RecentAlerts_$timestamp.csv") -NoTypeInformation
Write-Status "Captured $($alerts.Count) alert(s) in the lookback window" "OK"

if ($alerts.Count -gt 0) {
    $byName = $alerts | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 10
    Write-Host "`nTop repeating alert names (auto-resolution/tagging candidates):" -ForegroundColor Cyan
    $byName | ForEach-Object { Write-Host ("  {0,-4} {1}" -f $_.Count, $_.Name) }

    $lowSevResolved = $alerts | Where-Object { $_.Severity -eq "Low" -and $_.Status -eq "Resolved" }
    Write-Host "`nLow-severity, already-resolved alerts (manual triage overhead a rule could remove): $($lowSevResolved.Count)" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 4. RBAC gate for rule authorship
# ---------------------------------------------------------------------------
Write-Status "Auditing role membership for rule-authorship gate..."
$rbacResults = @()
foreach ($role in @("DLP Compliance Management", "View-Only DLP Compliance Management", "Information Protection")) {
    try {
        $members = Get-RoleGroupMember -Identity $role -ErrorAction Stop
        foreach ($m in $members) {
            $rbacResults += [PSCustomObject]@{ RoleGroup = $role; Member = $m.Name; RecipientType = $m.RecipientType }
        }
        if (-not $members) {
            $rbacResults += [PSCustomObject]@{ RoleGroup = $role; Member = "(none)"; RecipientType = "" }
        }
    } catch {
        Write-Status "Could not read role group '$role': $($_.Exception.Message)" "WARN"
    }
}
$rbacResults | Export-Csv -Path (Join-Path $OutputPath "DLPAlertOps_RBAC_$timestamp.csv") -NoTypeInformation

$dlpMgmtCount = ($rbacResults | Where-Object { $_.RoleGroup -eq "DLP Compliance Management" -and $_.Member -ne "(none)" }).Count
if ($dlpMgmtCount -eq 0) {
    Write-Status "No members found in DLP Compliance Management — nobody can author auto-resolution/tagging rules today" "WARN"
} elseif ($dlpMgmtCount -gt 5) {
    Write-Status "$dlpMgmtCount members in DLP Compliance Management — review for least-privilege before recommending rule adoption" "WARN"
} else {
    Write-Status "$dlpMgmtCount member(s) in DLP Compliance Management" "OK"
}

# ---------------------------------------------------------------------------
# 5. Portal-only checklist (cannot be queried programmatically)
# ---------------------------------------------------------------------------
Write-Host "`n=== Portal-only checklist (no cmdlet/Graph surface exists for these) ===" -ForegroundColor Yellow
Write-Host "  [ ] Confirm 'Alert rules' page is visible under Purview > Data Loss Prevention > Alerts"
Write-Host "  [ ] Confirm tenant cloud environment is Worldwide standard multi-tenant (initial GA target, Sept 2026)"
Write-Host "  [ ] Review any existing auto-resolution/tagging rule's stated conditions against this script's alert-name and severity breakdown above"
Write-Host "  [ ] Confirm every existing rule has a documented owner + review date (see DLPAlertAutoResolution-A.md, Remediation Playbook 1)"
Write-Host "  [ ] If recommending new rules: propose tag-only first, convert to auto-resolution only after one triage cycle of validation"

Write-Status "Audit complete. CSV exports written to $OutputPath" "OK"
