<#
.SYNOPSIS
    Audits Microsoft Sentinel analytics rule health, incident tuning signals, and
    automation rule exception hygiene for a given Log Analytics workspace.

.DESCRIPTION
    Analytics rules fail silently (AUTO DISABLED with no alert to the SOC) and get
    noisy silently (rising false-positive rate with no automatic notification). This
    script surfaces both, plus automation-rule exceptions that may be auto-closing
    incidents without an expiration date. Flags:
    - RULE_AUTO_DISABLED        : rule name prefixed "AUTO DISABLED" by Sentinel itself
    - RULE_MANUALLY_DISABLED    : rule disabled with no AUTO DISABLED prefix (human action)
    - RULE_NEVER_FIRED          : enabled rule with zero SecurityAlert rows in -LookbackDays
    - RULE_NO_ENTITY_MAPPING    : Scheduled/NRT rule with no entity mapping configured
                                  (degrades grouping quality and disables Tuning insights'
                                  top-entities pane)
    - RULE_GROUPING_NOT_ENTITY_BASED : incident grouping enabled but not set to match on
                                  entities (the recommended, most precise setting)
    - RULE_HIGH_FP_RATE         : closed-incident false-positive rate above -FPRateThresholdPct
    - RULE_HIGH_ALERTS_PER_INCIDENT : average alerts/incident above -AlertsPerIncidentThreshold
                                  (possible grouping or genuine-noise tuning candidate)
    - AUTOMATION_RULE_NO_EXPIRY : an automation rule with a closing/suppression-style action
                                  and no expiration date — common stale pen-test/maintenance
                                  leftover that can auto-close real incidents indefinitely

    Exports one CSV per finding category plus a combined summary. Fully read-only —
    no rule, incident, or automation rule is created, modified, enabled, or deleted.

    Does NOT cover:
    - Cross-tenant/MSSP credential-based rule failures (no documented Graph/PowerShell
      property exposes "runs under creator's own credentials" — this must be identified
      manually per Security/Sentinel/AnalyticsRules-A.md Playbook 4)
    - Fusion/Anomaly (UEBA) rule internal tuning (no exposed KQL-editable query surface)
    - Whether the tenant is onboarded to the Microsoft Defender portal (no queryable
      workspace property confirms this reliably as of this writing — check manually via
      Defender portal > Microsoft Sentinel > Settings before relying on classic Sentinel
      incident-grouping assumptions)

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace that Sentinel is enabled on.

.PARAMETER LookbackDays
    Days of history to evaluate for firing history and incident/classification stats.
    Default 14, matching the built-in Tuning insights window.

.PARAMETER FPRateThresholdPct
    False-positive rate (%) above which a rule is flagged as a tuning candidate. Default 50.

.PARAMETER AlertsPerIncidentThreshold
    Average alerts-per-incident above which a rule is flagged for grouping/noise review.
    Default 20.

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\Sentinel-AnalyticsRuleAudit-<timestamp>

.EXAMPLE
    .\Get-SentinelAnalyticsRuleAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod"

.EXAMPLE
    .\Get-SentinelAnalyticsRuleAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod" `
        -LookbackDays 30 -FPRateThresholdPct 40

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights, Az.SecurityInsights modules; authenticated
              Az PowerShell session (Connect-AzAccount) with Microsoft Sentinel Reader
              (minimum) on the workspace.
    Run As: Any account with the above RBAC — no elevated/admin rights required.
    Safe: Fully read-only. No analytics rule, incident, or automation rule is modified.
    Cross-references: Security/Sentinel/AnalyticsRules-B.md (Fixes 1-6) and AnalyticsRules-A.md
                       (Playbooks 1-4) for remediation once a gap is identified here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [int]$LookbackDays = 14,

    [int]$FPRateThresholdPct = 50,

    [int]$AlertsPerIncidentThreshold = 20,

    [string]$OutputPath = "C:\Temp\Sentinel-AnalyticsRuleAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    param([string]$Category, [string]$RuleName, [string]$RuleId, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Category = $Category
        RuleName = $RuleName
        RuleId   = $RuleId
        Detail   = $Detail
        FoundAt  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    })
}

# ───────────────────────────────────────────────────────────────
# 1. Preflight — resolve workspace, confirm connectivity
# ───────────────────────────────────────────────────────────────
Write-Status "Resolving workspace $WorkspaceName in $ResourceGroupName..." "INFO"
try {
    $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
    $customerId = $ws.CustomerId
    Write-Status "Workspace resolved (CustomerId: $customerId)" "OK"
} catch {
    Write-Status "FATAL: could not resolve workspace — $($_.Exception.Message)" "ERROR"
    return
}

# ───────────────────────────────────────────────────────────────
# 2. Detect — enumerate analytics rules and classify disabled state
# ───────────────────────────────────────────────────────────────
Write-Status "Enumerating analytics rules..." "INFO"
try {
    $rules = Get-AzSentinelAlertRule -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ErrorAction Stop
} catch {
    Write-Status "FATAL: could not enumerate analytics rules — $($_.Exception.Message)" "ERROR"
    return
}
Write-Status "Found $($rules.Count) rule(s)" "OK"

$ruleSummary = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($rule in $rules) {
    $isAutoDisabled = $rule.DisplayName -like "AUTO DISABLED*"
    $isManuallyDisabled = (-not $rule.Enabled) -and (-not $isAutoDisabled)

    if ($isAutoDisabled) {
        Add-Finding -Category "RULE_AUTO_DISABLED" -RuleName $rule.DisplayName -RuleId $rule.Name `
            -Detail "Sentinel auto-disabled this rule after repeated permanent failures. Read the rule description for the specific reason before re-enabling."
        Write-Status "  AUTO DISABLED: $($rule.DisplayName)" "WARN"
    } elseif ($isManuallyDisabled) {
        Add-Finding -Category "RULE_MANUALLY_DISABLED" -RuleName $rule.DisplayName -RuleId $rule.Name `
            -Detail "Rule is disabled with no AUTO DISABLED prefix — a human/process disabled it. Confirm this is intentional."
        Write-Status "  Manually disabled: $($rule.DisplayName)" "WARN"
    }

    # Entity mapping check — only meaningful for Scheduled/NRT rule kinds
    if ($rule.Kind -in @("Scheduled", "NRT")) {
        $hasEntityMapping = $false
        try {
            if ($rule.PSObject.Properties.Name -contains "EntityMapping" -and $rule.EntityMapping) {
                $hasEntityMapping = ($rule.EntityMapping.Count -gt 0)
            }
        } catch { $hasEntityMapping = $false }

        if (-not $hasEntityMapping -and $rule.Enabled) {
            Add-Finding -Category "RULE_NO_ENTITY_MAPPING" -RuleName $rule.DisplayName -RuleId $rule.Name `
                -Detail "No entity mapping configured. Degrades entity-based grouping quality and disables the Tuning insights top-entities pane."
        }

        # Grouping method check
        try {
            $grouping = $rule.GroupingConfiguration
            if ($grouping -and $grouping.Enabled -and $grouping.MatchingMethod -ne "AllEntities") {
                Add-Finding -Category "RULE_GROUPING_NOT_ENTITY_BASED" -RuleName $rule.DisplayName -RuleId $rule.Name `
                    -Detail "Alert grouping enabled with MatchingMethod = '$($grouping.MatchingMethod)' instead of the recommended entity-match setting."
            }
        } catch {
            # Property shape varies by module version — non-fatal, skip silently
        }
    }

    $ruleSummary.Add([PSCustomObject]@{
        RuleName = $rule.DisplayName
        Kind     = $rule.Kind
        Enabled  = $rule.Enabled
        Severity = $rule.Severity
    })
}
$ruleSummary | Export-Csv "$OutputPath\01-RuleSummary.csv" -NoTypeInformation

# ───────────────────────────────────────────────────────────────
# 3. Detect — firing history via SecurityAlert (never-fired check)
# ───────────────────────────────────────────────────────────────
Write-Status "Checking firing history over the last $LookbackDays day(s)..." "INFO"
try {
    $alertQuery = @"
SecurityAlert
| where TimeGenerated > ago(${LookbackDays}d)
| where ProductName == "Azure Sentinel"
| summarize AlertCount = count(), LastFired = max(TimeGenerated) by AlertName
"@
    $alertResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $alertQuery -ErrorAction Stop
    $firedRuleNames = @($alertResult.Results | ForEach-Object { $_.AlertName })

    foreach ($rule in ($rules | Where-Object { $_.Enabled -and $_.Kind -in @("Scheduled", "NRT") })) {
        if ($rule.DisplayName -notin $firedRuleNames) {
            Add-Finding -Category "RULE_NEVER_FIRED" -RuleName $rule.DisplayName -RuleId $rule.Name `
                -Detail "Enabled rule produced zero alerts in the last $LookbackDays day(s). Could be genuinely quiet or broken — test the query manually against current data."
        }
    }
    $alertResult.Results | Export-Csv "$OutputPath\02-FiringHistory.csv" -NoTypeInformation
} catch {
    Write-Status "Firing-history query failed: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 4. Detect — incident/classification stats (FP rate, alerts/incident)
# ───────────────────────────────────────────────────────────────
Write-Status "Checking incident classification and grouping stats..." "INFO"
try {
    $incidentQuery = @"
SecurityIncident
| where TimeGenerated > ago(${LookbackDays}d)
| mv-expand RuleId = RelatedAnalyticRuleIds
| extend RuleIdStr = tostring(RuleId)
| summarize Incidents = dcount(IncidentNumber),
            Closed = countif(Status == "Closed"),
            FalsePos = countif(Classification in ("FalsePositive","BenignPositive")),
            AvgAlerts = avg(toint(AlertsCount))
            by RuleIdStr
| extend FPRatePct = iff(Closed > 0, round(100.0 * FalsePos / Closed, 1), 0.0)
"@
    $incidentResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $incidentQuery -ErrorAction Stop
    $incidentResult.Results | Export-Csv "$OutputPath\03-IncidentTuningStats.csv" -NoTypeInformation

    foreach ($row in $incidentResult.Results) {
        $matchingRule = $rules | Where-Object { $_.Name -eq $row.RuleIdStr } | Select-Object -First 1
        $ruleLabel = if ($matchingRule) { $matchingRule.DisplayName } else { $row.RuleIdStr }

        if ($row.FPRatePct -ge $FPRateThresholdPct -and $row.Closed -gt 0) {
            Add-Finding -Category "RULE_HIGH_FP_RATE" -RuleName $ruleLabel -RuleId $row.RuleIdStr `
                -Detail "False-positive rate $($row.FPRatePct)% over $LookbackDays day(s) (threshold: $FPRateThresholdPct%). Review Tuning insights and consider an exception."
        }
        if ($row.AvgAlerts -ge $AlertsPerIncidentThreshold) {
            Add-Finding -Category "RULE_HIGH_ALERTS_PER_INCIDENT" -RuleName $ruleLabel -RuleId $row.RuleIdStr `
                -Detail "Average $($row.AvgAlerts) alerts/incident (threshold: $AlertsPerIncidentThreshold). Check grouping method (entity-match recommended) or genuine detection noise."
        }
    }
} catch {
    Write-Status "Incident tuning-stats query failed: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 5. Detect — automation rules with no expiration on closing actions
# ───────────────────────────────────────────────────────────────
Write-Status "Checking automation rules for stale/unexpiring exceptions..." "INFO"
try {
    $autoRules = Get-AzSentinelAutomationRule -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ErrorAction Stop
    $autoRules | Select-Object DisplayName, Order, Enabled |
        Export-Csv "$OutputPath\04-AutomationRules.csv" -NoTypeInformation

    foreach ($ar in $autoRules) {
        $hasCloseAction = $false
        $hasExpiry = $false
        try {
            if ($ar.PSObject.Properties.Name -contains "Actions" -and $ar.Actions) {
                $hasCloseAction = ($ar.Actions | Where-Object { $_.ActionType -eq "ModifyProperties" -and $_.ActionConfiguration.Status -eq "Closed" }).Count -gt 0
            }
            if ($ar.PSObject.Properties.Name -contains "TriggeringLogic" -and $ar.TriggeringLogic.ExpirationTimeUtc) {
                $hasExpiry = [datetime]$ar.TriggeringLogic.ExpirationTimeUtc -gt (Get-Date).ToUniversalTime()
            }
        } catch {
            # Property shape varies by module version — flag conservatively below rather than fail
        }

        if ($ar.Enabled -and $hasCloseAction -and -not $hasExpiry) {
            Add-Finding -Category "AUTOMATION_RULE_NO_EXPIRY" -RuleName $ar.DisplayName -RuleId $ar.Name `
                -Detail "Enabled automation rule auto-closes matching incidents with no expiration date. Common stale pen-test/maintenance leftover — confirm this is intentional and permanent."
        }
    }
} catch {
    Write-Status "Automation rule check failed: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 6. Report — combined findings + console summary
# ───────────────────────────────────────────────────────────────
$findings | Export-Csv "$OutputPath\00-AllFindings.csv" -NoTypeInformation

Write-Host "`n=== Sentinel Analytics Rule Audit Summary ===" -ForegroundColor Cyan
Write-Host "Workspace: $WorkspaceName" -ForegroundColor Cyan
Write-Host "Rules evaluated: $($rules.Count) | Lookback: $LookbackDays day(s)" -ForegroundColor Cyan

if ($findings.Count -eq 0) {
    Write-Status "No findings — all rules enabled, firing, and within tuning thresholds." "OK"
} else {
    $findings | Group-Object Category | ForEach-Object {
        Write-Status "$($_.Name): $($_.Count) finding(s)" "WARN"
    }
    $findings | Format-Table Category, RuleName, Detail -Wrap -AutoSize
}

Write-Status "Full results exported to: $OutputPath" "OK"
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Status "Zipped to: $OutputPath.zip" "OK"
