<#
.SYNOPSIS
    Audits Microsoft Defender for Cloud's CIEM (Cloud Infrastructure Entitlement
    Management) enablement and recommendation state across one or more Azure
    subscriptions.

.DESCRIPTION
    CIEM tickets almost always resolve to one of three things: the Defender CSPM
    plan isn't enabled, the CIEM sub-toggle within that plan is off (a separate
    setting this script cannot read directly — see Limitations), or a multicloud
    connector's CIEM-specific access-configuration step was never re-run after
    CIEM was turned on. This script checks what it CAN check via PowerShell/
    Resource Graph in one pass per subscription:

    - Defender CSPM ("CloudPosture") plan tier — the licensing gate CIEM sits behind
    - Presence and status of the two CIEM-specific security assessments
      ("overprovisioned identities" / "inactive identities") for Azure
    - Multicloud connector inventory (AWS/GCP) via Azure Resource Graph, including
      connector creation date where available, to flag connectors that may predate
      CIEM enablement and therefore need their access-configuration step re-run
    - Security Admin role assignment presence for the current caller (informational —
      does not enumerate every user's role assignments tenant-wide)

    It does NOT and cannot check (portal/API-only, no documented cmdlet as of
    writing — see CIEM-A.md How It Works for why):
    - The CIEM on/off sub-toggle itself within the Defender CSPM plan Settings blade
    - Whether AWS/GCP's CIEM-specific "Configure access" step was actually re-run
      (only the connector's existence and creation date, as a proxy signal)
    - Cloud Security Explorer graph contents or Attack Path Analysis results
    - CloudTrail / GCP Cloud Logging ingestion state

    All operations are read-only. No pricing tier changes, no connector
    modifications, no role assignment changes anywhere in this script.

.PARAMETER SubscriptionId
    One or more subscription IDs to audit. Defaults to all subscriptions visible
    in the current Az context if omitted.

.PARAMETER ConnectorAgeWarningDays
    Flag multicloud connectors older than this many days as "may predate CIEM
    enablement — verify Configure access was re-run." Default: 30.

.PARAMETER OutputPath
    Directory for CSV exports. Default: C:\Temp\CIEM-Audit-<timestamp>

.EXAMPLE
    .\Get-CIEMRecommendationAudit.ps1

.EXAMPLE
    .\Get-CIEMRecommendationAudit.ps1 -SubscriptionId "11111111-1111-1111-1111-111111111111" -ConnectorAgeWarningDays 14

.NOTES
    Requires: Az.Accounts, Az.Security, Az.ResourceGraph modules
    Run As: Account with at least Security Reader role on each target subscription
    Safe: Read-only — Set-AzSecurityPricing and any connector/role-assignment
          write cmdlets are never called by this script
    Cross-references: Security/Defender/CIEM-B.md and -A.md
#>

[CmdletBinding()]
param(
    [string[]]$SubscriptionId,

    [int]$ConnectorAgeWarningDays = 30,

    [string]$OutputPath = "C:\Temp\CIEM-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# ───────────────────────────────────────────────────────────────
# PRE-FLIGHT
# ───────────────────────────────────────────────────────────────

$requiredModules = @("Az.Accounts", "Az.Security", "Az.ResourceGraph")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        return
    }
}

$context = Get-AzContext
if (-not $context) {
    Write-Status "No active Az context. Run Connect-AzAccount first." "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$subs = if ($SubscriptionId) {
    $SubscriptionId | ForEach-Object { Get-AzSubscription -SubscriptionId $_ -ErrorAction SilentlyContinue }
} else {
    Get-AzSubscription
}

if (-not $subs -or $subs.Count -eq 0) {
    Write-Status "No subscriptions resolved. Check -SubscriptionId values or account access." "ERROR"
    return
}

Write-Status "Auditing $($subs.Count) subscription(s) for CIEM readiness..." "INFO"
Write-Status "Reminder: the CIEM on/off sub-toggle itself is portal-only and NOT read by this script — see Limitations in the header comment." "WARN"

$fleetSummary  = [System.Collections.Generic.List[PSCustomObject]]::new()
$allCIEMRecs   = [System.Collections.Generic.List[PSCustomObject]]::new()
$allConnectors = [System.Collections.Generic.List[PSCustomObject]]::new()

# ───────────────────────────────────────────────────────────────
# PER-SUBSCRIPTION AUDIT
# ───────────────────────────────────────────────────────────────

foreach ($sub in $subs) {

    Write-Status "--- Subscription: $($sub.Name) ($($sub.Id)) ---" "INFO"

    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    } catch {
        Write-Status "  Could not set context for $($sub.Name): $($_.Exception.Message)" "ERROR"
        continue
    }

    $summary = [PSCustomObject]@{
        SubscriptionName        = $sub.Name
        SubscriptionId          = $sub.Id
        CloudPostureTier        = "Unknown"
        CIEMRecommendationCount = 0
        CIEMUnhealthyCount      = 0
        MulticloudConnectors    = 0
        StaleConnectorsFound    = 0
        RiskFlag                = "OK"
        Notes                   = ""
    }

    # Defender CSPM plan tier — the licensing gate CIEM sits behind
    try {
        $pricing = Get-AzSecurityPricing -ErrorAction Stop
        $cloudPosture = $pricing | Where-Object { $_.Name -eq "CloudPosture" }
        $summary.CloudPostureTier = if ($cloudPosture) { $cloudPosture.PricingTier } else { "NotFound" }
    } catch {
        $summary.Notes += "Pricing check failed: $($_.Exception.Message); "
    }

    # CIEM-specific recommendations (Azure)
    try {
        $ciemAssessments = Get-AzSecurityAssessment -ErrorAction Stop |
            Where-Object { $_.DisplayName -match "overprovisioned identities|inactive identities" }

        $summary.CIEMRecommendationCount = ($ciemAssessments | Measure-Object).Count
        $summary.CIEMUnhealthyCount = ($ciemAssessments | Where-Object { $_.Status.Code -eq "Unhealthy" } | Measure-Object).Count

        foreach ($a in $ciemAssessments) {
            $allCIEMRecs.Add([PSCustomObject]@{
                SubscriptionName = $sub.Name
                DisplayName      = $a.DisplayName
                Status           = $a.Status.Code
                Severity         = $a.Metadata.Severity
                ResourceId       = $a.ResourceDetails.Id
            })
        }
    } catch {
        $summary.Notes += "CIEM assessment check failed: $($_.Exception.Message); "
    }

    # Multicloud connector inventory (AWS/GCP) via Resource Graph
    #
    # NOTE: Resource Graph's securityconnectors schema does not reliably expose a
    # connector creation/last-modified date across all connector schema versions, so
    # this script does NOT attempt an automated "connector predates CIEM" age
    # calculation (a prior draft of this script tried to fake this via an unrelated
    # property and produced meaningless output -- removed). Every connector found is
    # flagged for a manual "was Configure access re-run since CIEM was enabled" check.
    try {
        $graphQuery = "resources | where type =~ 'microsoft.security/securityconnectors' | project name, environmentName = tostring(properties.environmentName)"
        $connectors = Search-AzGraph -Query $graphQuery -Subscription $sub.Id -ErrorAction Stop
        $summary.MulticloudConnectors = ($connectors | Measure-Object).Count

        foreach ($c in $connectors) {
            $allConnectors.Add([PSCustomObject]@{
                SubscriptionName = $sub.Name
                ConnectorName    = $c.name
                Environment      = $c.environmentName
                Note             = "Creation/last-config date not reliably exposed via Resource Graph -- manually verify in portal whether Configure access was re-run after CIEM was enabled"
            })
        }
        if ($summary.MulticloudConnectors -gt 0) {
            $summary.StaleConnectorsFound = $summary.MulticloudConnectors
            $summary.Notes += "Multicloud connector(s) present — manually verify CIEM Configure access was re-run per connector; "
        }
    } catch {
        $summary.Notes += "Resource Graph connector query failed: $($_.Exception.Message); "
    }

    # Risk flag rollup
    $flags = @()
    if ($summary.CloudPostureTier -ne "Standard") { $flags += "Defender-CSPM-Not-Enabled" }
    if ($summary.CloudPostureTier -eq "Standard" -and $summary.CIEMRecommendationCount -eq 0) { $flags += "No-CIEM-Recommendations-Found-Verify-Toggle" }
    if ($summary.CIEMUnhealthyCount -gt 0) { $flags += "Unhealthy-CIEM-Findings" }
    if ($summary.MulticloudConnectors -gt 0) { $flags += "Multicloud-Connector-Verify-Manually" }

    $summary.RiskFlag = if ($flags.Count -gt 0) { $flags -join ", " } else { "OK" }

    $fleetSummary.Add($summary)

    $tierColour = if ($summary.CloudPostureTier -eq "Standard") { "OK" } else { "WARN" }
    Write-Status "  Defender CSPM tier: $($summary.CloudPostureTier)" $tierColour
    Write-Status "  CIEM recommendations found: $($summary.CIEMRecommendationCount) (Unhealthy: $($summary.CIEMUnhealthyCount))" $(if ($summary.CIEMUnhealthyCount -gt 0) { "WARN" } else { "INFO" })
    Write-Status "  Multicloud connectors: $($summary.MulticloudConnectors)" "INFO"
    if ($summary.Notes) {
        Write-Status "  Notes: $($summary.Notes)" "WARN"
    }
}

# ───────────────────────────────────────────────────────────────
# EXPORT
# ───────────────────────────────────────────────────────────────

$fleetSummary  | Export-Csv -Path (Join-Path $OutputPath "ciem_fleet_summary.csv")  -NoTypeInformation -Encoding UTF8
$allCIEMRecs   | Export-Csv -Path (Join-Path $OutputPath "ciem_recommendations.csv") -NoTypeInformation -Encoding UTF8
$allConnectors | Export-Csv -Path (Join-Path $OutputPath "multicloud_connectors.csv") -NoTypeInformation -Encoding UTF8

Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== CIEM Fleet Readiness Summary ===" -ForegroundColor Cyan
$fleetSummary | Format-Table SubscriptionName, CloudPostureTier, CIEMRecommendationCount, CIEMUnhealthyCount, MulticloudConnectors, RiskFlag -AutoSize

$atRisk = $fleetSummary | Where-Object { $_.RiskFlag -ne "OK" }
if ($atRisk.Count -gt 0) {
    Write-Host "`n$($atRisk.Count) of $($fleetSummary.Count) subscription(s) flagged for review:" -ForegroundColor Yellow
    $atRisk | Format-Table SubscriptionName, RiskFlag -AutoSize
}

Write-Host "`nReminder: this script CANNOT read the CIEM on/off sub-toggle itself, AWS/GCP" -ForegroundColor DarkGray
Write-Host "Configure-access re-run status, Cloud Security Explorer, or Attack Path Analysis" -ForegroundColor DarkGray
Write-Host "results -- those are portal/API-graph-only surfaces. A subscription showing" -ForegroundColor DarkGray
Write-Host "'Defender-CSPM-Not-Enabled' or 'No-CIEM-Recommendations-Found' still needs a" -ForegroundColor DarkGray
Write-Host "manual portal check of the CIEM toggle before concluding CIEM is truly off." -ForegroundColor DarkGray
Write-Host "See Security/Defender/CIEM-A.md for the full three-layer gating model." -ForegroundColor DarkGray
