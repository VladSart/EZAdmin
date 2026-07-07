<#
.SYNOPSIS
    Audits Microsoft Defender for Cloud (CSPM) posture for one or more Azure
    subscriptions — plan tiers, Secure Score, unhealthy recommendations, and
    multicloud (AWS/GCP) connector coverage.

.DESCRIPTION
    Most Defender for Cloud CSPM tickets resolve to one of three things: a plan-tier
    gap (Foundational vs. Defender CSPM), a Secure Score drop from a genuine new
    misconfiguration, or a multicloud connector that's missing/broken. This script
    checks all three in one pass, per subscription, and produces a per-subscription
    risk rollup plus a detailed unhealthy-assessment export.

    Specifically, it collects:
    - CloudPosture (and other Defender) plan pricing tier per subscription
    - Secure Score (overall) and per-control breakdown, sorted by unhealthy count
    - Full list of Unhealthy security assessments, with severity
    - Multicloud connector inventory via Azure Resource Graph
      (microsoft.security/securityconnectors), flagging subscriptions with zero
      connectors so MSP fleet reviews can spot AWS/GCP coverage gaps
    - Resource locks on connector resources (a common cause of "can't delete/
      re-add a stuck connector" tickets)

    It does NOT and cannot check (these require cloud-provider-side access or
    live portal state — see DefenderForCloud-B.md / -A.md for those paths):
    - AWS CloudFormation stack/StackSet health (requires AWS-side access)
    - GCP org policy state, e.g. the disk-scanning restriction (requires GCP
      Console/gcloud access)
    - Attack path analysis / Cloud Security Explorer graph contents (no
      PowerShell cmdlet surfaces this; portal/API only)
    - Azure Arc agent connectivity for on-prem/hybrid machines — see
      Azure/Arc/Scripts/Get-AzureArcAgentHealth.ps1 for that layer

    All operations are read-only. No pricing tier changes, no policy
    remediation, no connector create/delete/update calls anywhere in this
    script.

.PARAMETER SubscriptionId
    One or more subscription IDs to audit. Defaults to all subscriptions
    visible in the current Az context if omitted.

.PARAMETER WarningSecureScorePercent
    Secure Score percentage below which a subscription is flagged WARNING.
    Default: 60.

.PARAMETER OutputPath
    Directory for CSV exports. Default: C:\Temp\DefenderForCloud-Audit-<timestamp>

.EXAMPLE
    .\Get-DefenderForCloudPostureAudit.ps1

.EXAMPLE
    .\Get-DefenderForCloudPostureAudit.ps1 -SubscriptionId "11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222" -WarningSecureScorePercent 70

.NOTES
    Requires: Az.Accounts, Az.Security, Az.ResourceGraph, Az.Resources modules
    Run As: Account with at least Security Reader role on each target subscription
    Safe: Read-only — Set-AzSecurityPricing, remediation tasks, and connector
          add/remove cmdlets are never called by this script
    Cross-references: Security/Defender/DefenderForCloud-B.md and -A.md
#>

[CmdletBinding()]
param(
    [string[]]$SubscriptionId,

    [int]$WarningSecureScorePercent = 60,

    [string]$OutputPath = "C:\Temp\DefenderForCloud-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

$requiredModules = @("Az.Accounts", "Az.Security", "Az.ResourceGraph", "Az.Resources")
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

Write-Status "Auditing $($subs.Count) subscription(s)..." "INFO"

$fleetSummary       = [System.Collections.Generic.List[PSCustomObject]]::new()
$allUnhealthy       = [System.Collections.Generic.List[PSCustomObject]]::new()
$allConnectors      = [System.Collections.Generic.List[PSCustomObject]]::new()
$allLocks           = [System.Collections.Generic.List[PSCustomObject]]::new()

# ───────────────────────────────────────────────────────────────
# PER-SUBSCRIPTION AUDIT
# ───────────────────────────────────────────────────────────────

foreach ($sub in $subs) {

    Write-Status "─── Subscription: $($sub.Name) ($($sub.Id)) ───" "INFO"

    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    } catch {
        Write-Status "  Could not set context for $($sub.Name): $($_.Exception.Message)" "ERROR"
        continue
    }

    $summary = [PSCustomObject]@{
        SubscriptionName       = $sub.Name
        SubscriptionId         = $sub.Id
        CloudPostureTier       = "Unknown"
        DefenderServersTier    = "Unknown"
        SecureScoreCurrent     = $null
        SecureScoreMax         = $null
        SecureScorePercent     = $null
        UnhealthyCount         = 0
        UnhealthyHighSeverity  = 0
        MulticloudConnectors   = 0
        ConnectorLocksFound    = 0
        RiskFlag               = "OK"
        Notes                  = ""
    }

    # Plan tiers
    try {
        $pricing = Get-AzSecurityPricing -ErrorAction Stop
        $cloudPosture = $pricing | Where-Object { $_.Name -eq "CloudPosture" }
        $servers      = $pricing | Where-Object { $_.Name -eq "VirtualMachines" }
        $summary.CloudPostureTier    = if ($cloudPosture) { $cloudPosture.PricingTier } else { "NotFound" }
        $summary.DefenderServersTier = if ($servers)      { $servers.PricingTier }      else { "NotFound" }
    } catch {
        $summary.Notes += "Pricing check failed: $($_.Exception.Message); "
    }

    # Secure Score
    try {
        $score = Get-AzSecuritySecureScore -ErrorAction Stop | Select-Object -First 1
        if ($score) {
            $summary.SecureScoreCurrent = $score.Score.Current
            $summary.SecureScoreMax     = $score.Score.Max
            if ($score.Score.Max -gt 0) {
                $summary.SecureScorePercent = [math]::Round(($score.Score.Current / $score.Score.Max) * 100, 1)
            }
        }
    } catch {
        $summary.Notes += "Secure Score check failed: $($_.Exception.Message); "
    }

    # Unhealthy assessments
    try {
        $assessments = Get-AzSecurityAssessment -ErrorAction Stop | Where-Object { $_.Status.Code -eq "Unhealthy" }
        $summary.UnhealthyCount = ($assessments | Measure-Object).Count
        $summary.UnhealthyHighSeverity = ($assessments | Where-Object { $_.Metadata.Severity -eq "High" } | Measure-Object).Count

        foreach ($a in $assessments) {
            $allUnhealthy.Add([PSCustomObject]@{
                SubscriptionName = $sub.Name
                DisplayName      = $a.DisplayName
                Severity         = $a.Metadata.Severity
                ResourceId       = $a.ResourceDetails.Id
                Description      = $a.Metadata.Description
            })
        }
    } catch {
        $summary.Notes += "Assessment check failed: $($_.Exception.Message); "
    }

    # Multicloud connectors (Resource Graph — subscription-scoped)
    try {
        $graphQuery = "resources | where type =~ 'microsoft.security/securityconnectors' | project name, environmentName = tostring(properties.environmentName), environmentData = properties.environmentData"
        $connectors = Search-AzGraph -Query $graphQuery -Subscription $sub.Id -ErrorAction Stop
        $summary.MulticloudConnectors = ($connectors | Measure-Object).Count

        foreach ($c in $connectors) {
            $allConnectors.Add([PSCustomObject]@{
                SubscriptionName = $sub.Name
                ConnectorName    = $c.name
                Environment      = $c.environmentName
            })
        }
    } catch {
        $summary.Notes += "Resource Graph connector query failed: $($_.Exception.Message); "
    }

    # Resource locks on connector resources
    try {
        $locks = Get-AzResourceLock -ErrorAction SilentlyContinue | Where-Object { $_.ResourceId -match "securityconnectors" }
        $summary.ConnectorLocksFound = ($locks | Measure-Object).Count
        foreach ($l in $locks) {
            $allLocks.Add([PSCustomObject]@{
                SubscriptionName = $sub.Name
                LockName         = $l.Name
                ResourceId       = $l.ResourceId
                LockLevel        = $l.Properties.level
            })
        }
    } catch {
        $summary.Notes += "Resource lock check failed: $($_.Exception.Message); "
    }

    # Risk flag rollup
    $flags = @()
    if ($summary.CloudPostureTier -eq "Free")               { $flags += "Foundational-CSPM-only" }
    if ($summary.SecureScorePercent -ne $null -and $summary.SecureScorePercent -lt $WarningSecureScorePercent) { $flags += "Low-Secure-Score" }
    if ($summary.UnhealthyHighSeverity -gt 0)                { $flags += "High-Severity-Findings" }
    if ($summary.ConnectorLocksFound -gt 0)                  { $flags += "Connector-Lock-Present" }

    $summary.RiskFlag = if ($flags.Count -gt 0) { $flags -join ", " } else { "OK" }

    $fleetSummary.Add($summary)

    $tierColour = if ($summary.CloudPostureTier -eq "Standard") { "OK" } else { "WARN" }
    Write-Status "  CloudPosture tier: $($summary.CloudPostureTier)" $tierColour
    Write-Status "  Secure Score: $($summary.SecureScoreCurrent)/$($summary.SecureScoreMax) ($($summary.SecureScorePercent)%)" "INFO"
    Write-Status "  Unhealthy assessments: $($summary.UnhealthyCount) (High severity: $($summary.UnhealthyHighSeverity))" $(if ($summary.UnhealthyHighSeverity -gt 0) { "WARN" } else { "INFO" })
    Write-Status "  Multicloud connectors: $($summary.MulticloudConnectors)" "INFO"
    if ($summary.ConnectorLocksFound -gt 0) {
        Write-Status "  Resource locks on connectors: $($summary.ConnectorLocksFound)" "WARN"
    }
    if ($summary.Notes) {
        Write-Status "  Notes: $($summary.Notes)" "WARN"
    }
}

# ───────────────────────────────────────────────────────────────
# EXPORT
# ───────────────────────────────────────────────────────────────

$fleetSummary  | Export-Csv -Path (Join-Path $OutputPath "fleet_summary.csv")       -NoTypeInformation -Encoding UTF8
$allUnhealthy  | Export-Csv -Path (Join-Path $OutputPath "unhealthy_assessments.csv") -NoTypeInformation -Encoding UTF8
$allConnectors | Export-Csv -Path (Join-Path $OutputPath "multicloud_connectors.csv") -NoTypeInformation -Encoding UTF8
$allLocks      | Export-Csv -Path (Join-Path $OutputPath "connector_locks.csv")       -NoTypeInformation -Encoding UTF8

Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== Defender for Cloud Fleet Posture Summary ===" -ForegroundColor Cyan
$fleetSummary | Format-Table SubscriptionName, CloudPostureTier, SecureScorePercent, UnhealthyHighSeverity, MulticloudConnectors, RiskFlag -AutoSize

$atRisk = $fleetSummary | Where-Object { $_.RiskFlag -ne "OK" }
if ($atRisk.Count -gt 0) {
    Write-Host "`n$($atRisk.Count) of $($fleetSummary.Count) subscription(s) flagged for review:" -ForegroundColor Yellow
    $atRisk | Format-Table SubscriptionName, RiskFlag -AutoSize
}

Write-Host "`nNote: AWS CloudFormation/StackSet health, GCP organization policy state, and" -ForegroundColor DarkGray
Write-Host "attack path graph contents are not visible via PowerShell — check the Defender" -ForegroundColor DarkGray
Write-Host "for Cloud portal or the relevant cloud provider console for those. Azure Arc" -ForegroundColor DarkGray
Write-Host "agent health for on-prem/hybrid machines is a separate prerequisite layer —" -ForegroundColor DarkGray
Write-Host "see Azure/Arc/Scripts/Get-AzureArcAgentHealth.ps1." -ForegroundColor DarkGray
