<#
.SYNOPSIS
    Read-only tenant-wide readiness/results audit for Microsoft Entra ID
    Governance Account Discovery — the licensing/RBAC gates AccountDiscovery-A.md
    and AccountDiscovery-B.md describe, plus a per-app matching-attribute-type
    and existing-report summary.

.DESCRIPTION
    Runs four independent checks and combines them into a single report:

    1. TENANT LICENSING (best-effort) — reads Get-MgSubscribedSku and flags
       whether a SKU matching the Entra ID Governance add-on or Entra Suite
       naming pattern is present with consumed/enabled units. This is a
       best-effort STRING match against SkuPartNumber, not a hardcoded SKU
       GUID — Microsoft's SKU naming is not guaranteed stable, and this check
       is explicitly flagged in output as requiring manual confirmation
       against the tenant's actual purchased licenses (per this repo's
       standing "never guess a GUID/SKU" discipline).

    2. TRIGGER-RBAC INVENTORY — enumerates every principal holding
       Application Administrator, Cloud Application Administrator, or
       Hybrid Identity Administrator — the three roles AccountDiscovery-A.md's
       Dependency Stack documents as required to TRIGGER a new discovery run
       (distinct from, and narrower than, the roles that can merely read an
       existing report).

    3. PER-APP PROVISIONING + MATCHING-ATTRIBUTE-TYPE CHECK — for every
       Service Principal with an active synchronization job, reads the
       synchronization schema and flags MATCHING_ATTRIBUTE_IS_EXPRESSION for
       any object mapping whose "match objects using this attribute" rule
       resolves to an Expression-type source rather than a Direct attribute —
       the single most common root cause of a whole-report MissingJoiningProperty
       failure documented in AccountDiscovery-B.md Fix 3. Also flags
       NO_MATCHING_ATTRIBUTE_CONFIGURED where no matching rule is found at all.

    4. EXISTING CORRELATION REPORT SUMMARY — for every Service Principal
       found in Check 3, queries the beta identityCorrelation reporting
       endpoint (GET /beta/reports/correlations) for the most recent report
       and, if one exists, its per-identity status breakdown
       (uncorrelated / correlatedNotAssigned / correlatedAssigned /
       failToCorrelate). Flags REPORT_HAS_ERROR for a populated top-level
       error and HIGH_UNCORRELATED_RATIO where uncorrelated accounts exceed
       a configurable threshold of total identities — a proxy signal for a
       possible matching-attribute problem even when the report itself
       completed without a hard error.

    Read-only throughout. Makes no changes to any policy, role assignment,
    provisioning job, mapping, or Service Principal, and does NOT trigger a
    new discovery run (there is no documented Graph write/start endpoint for
    that action — see Known Gaps below). Exports a full CSV plus a filtered
    "review needed" CSV.

    Does NOT cover (see AccountDiscovery-A.md "Does not cover" / Known Gaps):
    - Triggering a new Discover identities run — no Graph API exists for
      this; it is portal-only (Enterprise Apps → [App] → Provisioning →
      Discover identities)
    - Per-connector pagination/RFC 7644 §3.4.2.4 compliance — this can only
      be observed via actual discovery-report behavior, not queried in advance
    - Individual identity-level attribute mismatch diagnosis (e.g. comparing
      a specific user's matching-attribute value against the target app's
      own record) — see AccountDiscovery-B.md Fix 4 for that manual check
    - Whether a given Service Principal's connector TYPE is on the
      explicitly-unsupported list (Workday/SuccessFactors/ServiceNow/AWS/
      Snowflake/Cross-tenant sync/Cloud sync/Group-to-AD) — connector type
      isn't reliably exposed as a queryable Graph property distinct from the
      synchronization template ID; cross-check manually against
      AccountDiscovery-A.md's connector support matrix
    - Assign-CorrelatedUsers.ps1's own required Graph write scopes — that
      script is Microsoft-hosted and downloaded separately
      (aka.ms/AssignCorrelatedUsersPowerShell), not part of this repo

.PARAMETER UncorrelatedRatioThreshold
    Fraction (0.0-1.0) of a report's total identities that must be
    'uncorrelated' before HIGH_UNCORRELATED_RATIO is flagged. Defaults to 0.5
    (50%). Lower this for apps expected to be nearly fully provisioned already.

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to
    $env:TEMP\AccountDiscoveryAudit-<timestamp>.

.EXAMPLE
    .\Get-AccountDiscoveryReadinessAudit.ps1

    Standard audit — licensing, trigger-RBAC inventory, per-app matching
    attribute type, and existing report summaries at the default 50% threshold.

.EXAMPLE
    .\Get-AccountDiscoveryReadinessAudit.ps1 -UncorrelatedRatioThreshold 0.25 -OutputPath C:\Reports\AcctDiscovery

    Flags any app whose most recent report is more than 25% uncorrelated,
    custom output folder.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
              Microsoft.Graph.Identity.DirectoryManagement
    Scopes needed: Directory.Read.All, RoleManagement.Read.Directory,
                   Application.Read.All, ProvisioningLog.Read.All
    Run As: Any account with Global Reader (sufficient for every read this
            script performs) or a role with equivalent read scopes. Note this
            is deliberately broader than the Application/Cloud Application/
            Hybrid Identity Administrator roles required to actually TRIGGER
            a discovery run in the portal — this script only reads.
    Safe: Fully read-only — no Set-Mg/New-Mg/Remove-Mg/Update-Mg cmdlet and no
          POST/PATCH/DELETE Invoke-MgGraphRequest call appears anywhere in
          this script's executable code. Zero discovery runs are triggered.
    Cross-references: EntraID/Troubleshooting/AccountDiscovery-B.md (Triage,
                       Fix 3, Fix 5, Fix 9) and AccountDiscovery-A.md
                       (Dependency Stack, Validation Steps 1-7).
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [ValidateRange(0.0, 1.0)]
    [double]$UncorrelatedRatioThreshold = 0.5,

    [string]$OutputPath = "$env:TEMP\AccountDiscoveryAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

$triggerRbacRoles = @(
    "Application Administrator",
    "Cloud Application Administrator",
    "Hybrid Identity Administrator"
)

# ---- Preflight ----
foreach ($mod in @("Microsoft.Graph.Authentication", "Microsoft.Graph.Applications", "Microsoft.Graph.Identity.DirectoryManagement")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod" "ERROR"
        return
    }
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Graph. Connecting with required read scopes..." "INFO"
    try {
        Connect-MgGraph -Scopes "Directory.Read.All", "RoleManagement.Read.Directory", "Application.Read.All", "ProvisioningLog.Read.All" -NoWelcome -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        return
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

# =====================================================================
# CHECK 1 — Tenant licensing (best-effort SKU name match)
# =====================================================================
Write-Status "Checking tenant licensing for Entra ID Governance add-on / Entra Suite (best-effort name match)..." "INFO"
$licenseOk = $false
try {
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop
    $govSkus = $skus | Where-Object { $_.SkuPartNumber -match "GOVERNANCE|ENTRAID_GOVERNANCE|EntraSuite|Entra_Suite|ENTRA_SUITE" }

    if ($govSkus) {
        foreach ($s in $govSkus) {
            $enabled = ($s.PrepaidUnits).Enabled
            Write-Status "Found candidate SKU '$($s.SkuPartNumber)' — Enabled: $enabled, Consumed: $($s.ConsumedUnits)" "OK"
        }
        $licenseOk = $true
    }
    else {
        Write-Status "No SKU matched an Entra ID Governance / Entra Suite naming pattern. This is a best-effort string match — CONFIRM MANUALLY against the tenant's actual purchased licenses before concluding the feature is unavailable." "WARN"
    }
}
catch {
    Write-Status "Could not read subscribed SKUs: $($_.Exception.Message)" "ERROR"
}

# =====================================================================
# CHECK 2 — Trigger-RBAC inventory (Application/Cloud Application/Hybrid Identity Administrator)
# =====================================================================
Write-Status "Enumerating principals holding Account-Discovery-trigger-eligible roles..." "INFO"
try {
    $directoryRoles = Get-MgDirectoryRole -All -ErrorAction Stop | Where-Object { $_.DisplayName -in $triggerRbacRoles }

    if (-not $directoryRoles) {
        Write-Status "None of the trigger-eligible roles are currently activated in this tenant (roles only appear via Get-MgDirectoryRole once at least one principal has been assigned). If discovery has never been triggered, this can be expected." "WARN"
    }

    foreach ($role in $directoryRoles) {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop
        foreach ($m in $members) {
            $findings.Add([PSCustomObject]@{
                Category = "TriggerRBAC"; Identifier = $m.Id
                Flag = "TRIGGER_RBAC_HOLDER"
                Detail = "Holds '$($role.DisplayName)' — eligible to trigger a new Account Discovery run (RoleId: $($role.Id))"
                RiskLevel = "INFO"
            })
        }
    }
    Write-Status "Found $($findings.Count) trigger-RBAC role holder(s) across $($directoryRoles.Count) eligible role(s)." "OK"
}
catch {
    Write-Status "Could not enumerate directory role membership: $($_.Exception.Message)" "ERROR"
}

# =====================================================================
# CHECK 3 — Per-app provisioning + matching-attribute-type check
# =====================================================================
Write-Status "Enumerating Service Principals with active synchronization jobs..." "INFO"
$appRows = [System.Collections.Generic.List[object]]::new()

try {
    $servicePrincipals = Get-MgServicePrincipal -All -Property Id, DisplayName, AppId -ErrorAction Stop
}
catch {
    Write-Status "Failed to enumerate Service Principals: $($_.Exception.Message)" "ERROR"
    $servicePrincipals = @()
}

$appsWithJobs = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($sp in $servicePrincipals) {
    $i++
    if ($i % 100 -eq 0) { Write-Status "Scanned $i of $($servicePrincipals.Count) Service Principals for provisioning jobs..." "INFO" }

    try {
        $jobs = Get-MgServicePrincipalSynchronizationJob -ServicePrincipalId $sp.Id -ErrorAction Stop
    }
    catch { continue }

    foreach ($job in $jobs) {
        $appsWithJobs.Add([PSCustomObject]@{ ServicePrincipal = $sp; Job = $job })

        $matchingAttributeIsExpression = $false
        $matchingAttributeFound = $false
        $matchingAttributeName = ""

        try {
            $schema = Get-MgServicePrincipalSynchronizationJobSchema -ServicePrincipalId $sp.Id -SynchronizationJobId $job.Id -ErrorAction Stop
            foreach ($mapping in $schema.SynchronizationRules[0].ObjectMappings) {
                $matchAttrs = $mapping.AttributeMappings | Where-Object { $_.MatchingPriority -ne $null -and $_.MatchingPriority -ge 0 }
                $primaryMatch = $matchAttrs | Sort-Object MatchingPriority | Select-Object -First 1
                if ($primaryMatch) {
                    $matchingAttributeFound = $true
                    $matchingAttributeName = if ($primaryMatch.Source.Name) { $primaryMatch.Source.Name } else { "(expression)" }
                    if ($primaryMatch.Source.Type -eq "Function" -or $primaryMatch.Source.Expression) {
                        $matchingAttributeIsExpression = $true
                    }
                    break
                }
            }
        }
        catch {
            Write-Status "Could not read synchronization schema for '$($sp.DisplayName)': $($_.Exception.Message)" "WARN"
        }

        $appRows.Add([PSCustomObject]@{
            AppDisplayName          = $sp.DisplayName
            ServicePrincipalId      = $sp.Id
            JobStatusCode           = $job.Status.Code
            MatchingAttributeFound  = $matchingAttributeFound
            MatchingAttributeName   = $matchingAttributeName
            MatchingAttributeIsExpression = $matchingAttributeIsExpression
        })

        if (-not $matchingAttributeFound) {
            $findings.Add([PSCustomObject]@{
                Category = "MatchingAttribute"; Identifier = $sp.DisplayName
                Flag = "NO_MATCHING_ATTRIBUTE_CONFIGURED"
                Detail = "No matching-priority attribute mapping found in the synchronization schema — Account Discovery will not be able to correlate any identity for this app."
                RiskLevel = "HIGH"
            })
        }
        elseif ($matchingAttributeIsExpression) {
            $findings.Add([PSCustomObject]@{
                Category = "MatchingAttribute"; Identifier = $sp.DisplayName
                Flag = "MATCHING_ATTRIBUTE_IS_EXPRESSION"
                Detail = "Matching attribute resolves to an Expression/Function-type source rather than a Direct attribute — Account Discovery correlation will fail with MissingJoiningProperty even though ordinary provisioning is unaffected. See AccountDiscovery-B.md Fix 3."
                RiskLevel = "HIGH"
            })
        }
    }
}

# =====================================================================
# CHECK 4 — Existing correlation report summary (per app found in Check 3)
# =====================================================================
Write-Status "Checking for existing Account Discovery correlation reports on $($appsWithJobs.Count) provisioned app(s)..." "INFO"
$reportRows = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $appsWithJobs) {
    $sp = $entry.ServicePrincipal
    try {
        $reportsResp = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/beta/reports/correlations?`$filter=servicePrincipal/id eq '$($sp.Id)'" -ErrorAction Stop
        $latest = $reportsResp.value | Sort-Object startDateTime -Descending | Select-Object -First 1

        if (-not $latest) {
            $reportRows.Add([PSCustomObject]@{
                AppDisplayName = $sp.DisplayName; ServicePrincipalId = $sp.Id
                ReportId = ""; StartDateTime = ""; EndDateTime = ""; ErrorCode = ""
                Uncorrelated = 0; CorrelatedNotAssigned = 0; CorrelatedAssigned = 0; FailToCorrelate = 0
                TotalIdentities = 0; UncorrelatedRatio = 0
            })
            continue
        }

        if ($latest.error) {
            $findings.Add([PSCustomObject]@{
                Category = "CorrelationReport"; Identifier = $sp.DisplayName
                Flag = "REPORT_HAS_ERROR"
                Detail = "Most recent correlation report ($($latest.id)) failed with error code '$($latest.error.code)': $($latest.error.message)"
                RiskLevel = "HIGH"
            })
        }

        $counts = @{ uncorrelated = 0; correlatedNotAssigned = 0; correlatedAssigned = 0; failToCorrelate = 0 }
        $totalIdentities = 0

        try {
            $identitiesResp = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/beta/reports/correlations/$($latest.id)/identities?`$top=999" -ErrorAction Stop
            foreach ($ident in $identitiesResp.value) {
                if ($counts.ContainsKey($ident.status)) { $counts[$ident.status]++ }
                $totalIdentities++
            }
        }
        catch {
            Write-Status "Could not read identity results for report $($latest.id) ('$($sp.DisplayName)'): $($_.Exception.Message)" "WARN"
        }

        $ratio = if ($totalIdentities -gt 0) { [math]::Round($counts.uncorrelated / $totalIdentities, 2) } else { 0 }

        $reportRows.Add([PSCustomObject]@{
            AppDisplayName        = $sp.DisplayName
            ServicePrincipalId    = $sp.Id
            ReportId              = $latest.id
            StartDateTime         = $latest.startDateTime
            EndDateTime           = $latest.endDateTime
            ErrorCode             = $latest.error.code
            Uncorrelated          = $counts.uncorrelated
            CorrelatedNotAssigned = $counts.correlatedNotAssigned
            CorrelatedAssigned    = $counts.correlatedAssigned
            FailToCorrelate       = $counts.failToCorrelate
            TotalIdentities       = $totalIdentities
            UncorrelatedRatio     = $ratio
        })

        if ($totalIdentities -gt 0 -and $ratio -ge $UncorrelatedRatioThreshold -and -not $latest.error) {
            $findings.Add([PSCustomObject]@{
                Category = "CorrelationReport"; Identifier = $sp.DisplayName
                Flag = "HIGH_UNCORRELATED_RATIO"
                Detail = "$([math]::Round($ratio * 100))% of identities in the most recent report are uncorrelated (threshold: $([math]::Round($UncorrelatedRatioThreshold * 100))%) despite the report completing without a hard error — possible matching-attribute value mismatch, not necessarily a genuinely orphan-heavy population."
                RiskLevel = "MEDIUM"
            })
        }
    }
    catch {
        Write-Status "Could not query correlation reports for '$($sp.DisplayName)': $($_.Exception.Message)" "WARN"
    }
}

# =====================================================================
# Report
# =====================================================================
Write-Host ""
Write-Host "=== Account Discovery Readiness Audit Summary ===" -ForegroundColor Cyan

Write-Status "Tenant licensing (best-effort match): $(if ($licenseOk) { 'candidate SKU found — verify manually' } else { 'no candidate SKU found — verify manually' })" $(if ($licenseOk) { "OK" } else { "WARN" })

$triggerHolders = $findings | Where-Object { $_.Flag -eq "TRIGGER_RBAC_HOLDER" }
Write-Status "$($triggerHolders.Count) principal(s) hold trigger-eligible RBAC (Application/Cloud Application/Hybrid Identity Administrator)." "INFO"

$noMatchAttr = $findings | Where-Object { $_.Flag -eq "NO_MATCHING_ATTRIBUTE_CONFIGURED" }
$exprMatchAttr = $findings | Where-Object { $_.Flag -eq "MATCHING_ATTRIBUTE_IS_EXPRESSION" }
Write-Status "$($noMatchAttr.Count) app(s) with no matching attribute configured at all." $(if ($noMatchAttr.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "$($exprMatchAttr.Count) app(s) with an Expression-type matching attribute — Account Discovery will fail for these." $(if ($exprMatchAttr.Count -gt 0) { "WARN" } else { "OK" })

$reportErrors = $findings | Where-Object { $_.Flag -eq "REPORT_HAS_ERROR" }
$highUncorrelated = $findings | Where-Object { $_.Flag -eq "HIGH_UNCORRELATED_RATIO" }
Write-Status "$($reportErrors.Count) app(s) with a failed correlation report." $(if ($reportErrors.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "$($highUncorrelated.Count) app(s) with a suspiciously high uncorrelated ratio." $(if ($highUncorrelated.Count -gt 0) { "WARN" } else { "OK" })

$neverRun = $reportRows | Where-Object { -not $_.ReportId }
Write-Status "$($neverRun.Count) provisioned app(s) have never had a discovery run." "INFO"

Write-Host ""
if ($exprMatchAttr.Count -gt 0 -or $noMatchAttr.Count -gt 0) {
    Write-Host "--- Matching attribute issues (fix these before Discover identities will work) ---" -ForegroundColor Yellow
    ($noMatchAttr + $exprMatchAttr) | Select-Object Identifier, Flag, Detail | Format-Table -AutoSize -Wrap
}
if ($reportErrors.Count -gt 0) {
    Write-Host "--- Failed correlation reports ---" -ForegroundColor Red
    $reportErrors | Select-Object Identifier, Detail | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "KNOWN GAPS (not covered by this script — see .DESCRIPTION and AccountDiscovery-A.md):" -ForegroundColor DarkGray
Write-Host " - Triggering a new Discover identities run — no Graph write/start endpoint exists; portal-only" -ForegroundColor DarkGray
Write-Host " - Connector-type support (Workday/ServiceNow/AWS/Snowflake/Cross-tenant sync/Cloud sync/Group-to-AD are unsupported) — cross-check manually" -ForegroundColor DarkGray
Write-Host " - Individual identity attribute-value mismatch diagnosis — see AccountDiscovery-B.md Fix 4" -ForegroundColor DarkGray
Write-Host " - Assign-CorrelatedUsers.ps1's own required Graph write scopes (Microsoft-hosted script, downloaded separately)" -ForegroundColor DarkGray

$appsPath = Join-Path $OutputPath "MatchingAttributeInventory.csv"
$appRows | Export-Csv -Path $appsPath -NoTypeInformation -Encoding UTF8

$reportsPath = Join-Path $OutputPath "CorrelationReportSummary.csv"
$reportRows | Export-Csv -Path $reportsPath -NoTypeInformation -Encoding UTF8

$findingsPath = Join-Path $OutputPath "Findings.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8

Write-Status "Matching attribute inventory exported to $appsPath" "OK"
Write-Status "Correlation report summary exported to $reportsPath" "OK"
Write-Status "Findings exported to $findingsPath" "OK"
