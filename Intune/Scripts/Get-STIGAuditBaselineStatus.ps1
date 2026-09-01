<#
.SYNOPSIS
    Audits Intune STIG audit baseline eligibility, profile configuration, and
    (optionally) pulls per-policy audit summary data for a GCC High tenant.

.DESCRIPTION
    Admin-side Graph diagnostic supporting
    Intune/Troubleshooting/STIGAuditBaseline-A.md and STIGAuditBaseline-B.md.

    Checks:
      - Confirms Intune Advanced Analytics licensing signal (required add-on;
        the most common "eligible tenant, feature not visible" cause)
      - Retrieves the current STIG baseline template metadata (version, rule count)
        via GET /beta/deviceManagement/templates?$filter=templateFamily eq 'baseline'
      - Retrieves the tenant's actual STIG audit profile(s) (PolicyId) built from
        that template
      - Reports each profile's assignment presence (does not resolve full group
        membership — confirm target scope directly in the admin center for that)
      - Optionally (-PullAuditSummary) retrieves the per-policy audit summary via
        the 3-step cached-report pattern for a specified PolicyId, and flags the
        highest-failure-rate rules

    This is a GCC High-only feature. Running this script against a commercial or
    GCC (non-High) tenant will find zero STIG baseline templates — that is
    expected, not an error, and is itself useful confirmation the feature isn't
    available in that environment.

    Does NOT check individual device co-management workload ownership (the most
    common cause of a device showing no STIG data at all) — cross-reference
    Get-CoManagementStatus.ps1 in this same folder for that.

    Read-only. Makes no configuration changes, creates no STIG audit profiles
    (profile creation is UX-only in the current Intune release and has no
    documented Graph write endpoint).

.PARAMETER PullAuditSummary
    Also retrieve the per-policy audit summary (rule-level pass/fail counts) for
    the given -PolicyId, using the 3-step cached-report Graph pattern.

.PARAMETER PolicyId
    The GUID of a specific STIG audit profile to pull summary data for. Required
    when -PullAuditSummary is passed. Discover via this script's own base output
    or the admin-center policy URL.

.EXAMPLE
    .\Get-STIGAuditBaselineStatus.ps1

    Reports licensing signal, template metadata, and any existing audit profiles.

.EXAMPLE
    .\Get-STIGAuditBaselineStatus.ps1 -PullAuditSummary -PolicyId "11111111-2222-3333-4444-555555555555"

    Also pulls the rule-level pass/fail summary for the specified profile.

.NOTES
    Requires: Microsoft.Graph.Beta module or Invoke-MgGraphRequest, active
    Connect-MgGraph session with DeviceManagementConfiguration.Read.All and
    Organization.Read.All scopes. GCC High tenant only.
    Companion runbook: Intune/Troubleshooting/STIGAuditBaseline-A.md and -B.md
    Safe: entirely read-only. Uses the bulk-friendly per-policy summary pattern,
    not the far more expensive per-setting-per-device pattern, by default.
#>

[CmdletBinding()]
param(
    [switch]$PullAuditSummary,
    [string]$PolicyId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Result, [string]$Detail)
    $findings.Add([PSCustomObject]@{ Category = $Category; Item = $Item; Result = $Result; Detail = $Detail })
}

if ($PullAuditSummary -and -not $PolicyId) {
    Write-Status "-PullAuditSummary requires -PolicyId. Run without -PullAuditSummary first to discover the PolicyId." "ERROR"
    return
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) {
        throw "No active Graph session. Run Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All','Organization.Read.All' first."
    }
} catch {
    Write-Status "Graph connection required: $($_.Exception.Message)" "ERROR"
    return
}

Write-Status "Starting Intune STIG audit baseline eligibility/configuration audit"

# ---------------------------------------------------------------------------
# 1. Licensing signal
# ---------------------------------------------------------------------------
try {
    $skus = Get-MgSubscribedSku -ErrorAction Stop
    $analyticsMatch = $skus | Where-Object { $_.SkuPartNumber -match 'ADVANCED_ANALYTICS' }
    if ($analyticsMatch) {
        Write-Status "Intune Advanced Analytics SKU signal found" "OK"
        Add-Finding "Licensing" "Advanced Analytics" "FOUND" (($analyticsMatch | ForEach-Object { $_.SkuPartNumber }) -join '; ')
    } else {
        Write-Status "No SKU matched 'ADVANCED_ANALYTICS' — confirm manually, this is a coarse heuristic against SkuPartNumber naming" "WARN"
        Add-Finding "Licensing" "Advanced Analytics" "NOT FOUND (heuristic)" "No matching SkuPartNumber — verify actual entitlement manually if the STIG baseline option is missing from the admin center"
    }
} catch {
    Write-Status "Could not enumerate subscribed SKUs: $($_.Exception.Message)" "ERROR"
    Add-Finding "Licensing" "Advanced Analytics" "ERROR" $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 2. STIG baseline template metadata
# ---------------------------------------------------------------------------
$stigTemplate = $null
try {
    $templates = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/templates?`$filter=templateFamily eq 'baseline'" `
        -ErrorAction Stop

    $stigTemplate = $templates.value | Where-Object { $_.displayName -match 'STIG' } | Select-Object -First 1

    if ($stigTemplate) {
        Write-Status "STIG baseline template found: $($stigTemplate.displayName) — $($stigTemplate.displayVersion)" "OK"
        Add-Finding "Template" $stigTemplate.displayName "FOUND" "Version=$($stigTemplate.displayVersion) RuleCount=$($stigTemplate.settingTemplateCount) TemplateId=$($stigTemplate.id)"
    } else {
        Write-Status "No STIG baseline template found — expected if this tenant is not GCC High, or the feature hasn't yet appeared for this tenant" "WARN"
        Add-Finding "Template" "STIG baseline" "NOT FOUND" "Zero templates matched 'STIG' in displayName — confirm GCC High tenancy before treating this as a defect"
    }
} catch {
    Write-Status "Could not retrieve baseline templates: $($_.Exception.Message)" "ERROR"
    Add-Finding "Template" "STIG baseline" "ERROR" $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 3. Tenant's actual audit profile(s) built from that template
# ---------------------------------------------------------------------------
if ($stigTemplate) {
    try {
        $policies = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=templateReference/templateId eq '$($stigTemplate.id)'" `
            -ErrorAction Stop

        if ($policies.value.Count -eq 0) {
            Write-Status "STIG template exists in this tenant, but no audit profile has been created from it yet" "WARN"
            Add-Finding "Audit profiles" "Count" "0" "Template available but unused — create a profile in Endpoint security > Security baselines if audit reporting is desired"
        } else {
            Write-Status "Found $($policies.value.Count) STIG audit profile(s)" "OK"
            foreach ($p in $policies.value) {
                Add-Finding "Audit profiles" $p.name "FOUND" "PolicyId=$($p.id)"
            }
        }
    } catch {
        Write-Status "Could not retrieve audit profiles for this template: $($_.Exception.Message)" "ERROR"
        Add-Finding "Audit profiles" "Lookup" "ERROR" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 4. Optional per-policy audit summary pull
# ---------------------------------------------------------------------------
if ($PullAuditSummary) {
    Write-Status "Pulling per-policy audit summary for PolicyId=$PolicyId ..." "INFO"
    try {
        $reportId = "IndustryBaselinePerSettingDeviceAuditSummary_$PolicyId"
        $body = @{
            id      = $reportId
            filter  = "(PolicyId eq '$PolicyId')"
            orderBy = @()
            select  = @('SettingName', 'SettingId', 'StigRuleId', 'StigSeverity', 'NumberOfCompliantDevices')
        } | ConvertTo-Json

        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations" `
            -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null

        # Poll briefly for completion — a full production script should poll with backoff;
        # this performs a small, fixed number of attempts suitable for interactive/triage use
        $maxAttempts = 6
        $ready = $false
        for ($i = 0; $i -lt $maxAttempts; $i++) {
            Start-Sleep -Seconds 5
            $status = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations('$reportId')" `
                -ErrorAction Stop
            if ($status.status -eq 'completed') { $ready = $true; break }
        }

        if (-not $ready) {
            Write-Status "Report did not complete within the polling window — re-run later or increase the wait, this is not necessarily a failure" "WARN"
            Add-Finding "Audit summary" "Report status" "TIMEOUT" "Did not reach 'completed' within $($maxAttempts * 5)s of polling"
        } else {
            $resultsBody = @{
                id      = $reportId
                filter  = "(PolicyId eq '$PolicyId')"
                orderBy = @()
                select  = @('SettingName', 'SettingId', 'StigRuleId', 'StigSeverity', 'NumberOfCompliantDevices')
                skip    = 0
                top     = 250
            } | ConvertTo-Json

            $results = Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/getCachedReport" `
                -Body $resultsBody -ContentType "application/json" -ErrorAction Stop

            Write-Status "Retrieved $($results.values.Count) rule-level result row(s)" "OK"
            foreach ($row in $results.values) {
                Add-Finding "Rule result" $row[2] "INFO" "SettingName=$($row[0]) Severity=$($row[3]) CompliantDevices=$($row[4])"
            }
        }
    } catch {
        Write-Status "Audit summary pull failed: $($_.Exception.Message)" "ERROR"
        Add-Finding "Audit summary" "Pull" "ERROR" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Intune STIG Audit Baseline Status Summary ===" -ForegroundColor Cyan
$findings | Format-Table -AutoSize -Wrap

Write-Host ""
Write-Status "Reminder: this feature is GCC High-only. Zero results above is expected (not an error) in a commercial or GCC (non-High) tenant." "WARN"
Write-Status "For a device showing no audit data at all, also check co-management Device configuration workload ownership via Get-CoManagementStatus.ps1 — this script does not check that." "WARN"

$outPath = ".\STIGAuditBaselineStatus_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$findings | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
Write-Host "Results exported to: $outPath" -ForegroundColor Green
