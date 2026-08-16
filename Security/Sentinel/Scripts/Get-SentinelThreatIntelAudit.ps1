<#
.SYNOPSIS
    Audits Microsoft Sentinel threat intelligence health — current-schema ingestion,
    lingering dependency on the retired legacy table, and Upload API role configuration.

.DESCRIPTION
    Microsoft Sentinel's threat intelligence tables were split on 2025-07-31: the legacy
    ThreatIntelligenceIndicator table stopped receiving new data, replaced by
    ThreatIntelIndicators (indicator objects) and ThreatIntelObjects (all other STIX
    object types). This is a silent, no-error cutover — any analytics rule, hunting
    query, or workbook still referencing the legacy table simply stops seeing new
    threat intelligence with no visible failure. This script surfaces that gap plus
    Upload API role-assignment misconfiguration. Flags:
    - LEGACY_TABLE_STILL_WRITING : ThreatIntelligenceIndicator shows rows newer than
                                   2025-07-31 — either a stale integration or a false
                                   positive from a query that unions both tables
    - NO_CURRENT_TI_INGESTION    : both current-schema tables (ThreatIntelIndicators,
                                   ThreatIntelObjects) show zero rows in -LookbackHours —
                                   no active TI source is landing data at all
    - SOURCE_SYSTEM_GAP          : a SourceSystem seen historically has no rows in the
                                   lookback window — a specific connector may have gone
                                   quiet (auth expiry, vendor-side credential rotation)
    - UPLOAD_API_ROLE_MISSING    : supplied Entra app object ID does not hold "Microsoft
                                   Sentinel Contributor" at the specific workspace scope
                                   (subscription/resource-group-scoped grants do not count)

    Exports one CSV per finding category plus a combined summary. Fully read-only — no
    TI object, ingestion rule, or role assignment is created, modified, or deleted.

    Does NOT cover:
    - Ingestion rule logic/order review (no queryable KQL surface for rule definitions
      as of this writing — review via Sentinel/Defender portal > Threat intelligence >
      Ingestion rules per Security/Sentinel/ThreatIntelligence-A.md)
    - TAXII feed vendor-side credential validity (the script cannot verify a TAXII
      server's own API root/collection ID independent of Sentinel's own connector state)
    - Analytics rule query-text inspection for legacy table references (requires pulling
      and parsing each rule's KQL body — out of scope for a read-only health-audit script;
      do this manually per ThreatIntelligence-A.md Remediation Playbook 3)

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace that Sentinel is enabled on.

.PARAMETER LookbackHours
    Hours of history to evaluate for current ingestion activity. Default 24.

.PARAMETER SourceSystemLookbackDays
    Days of history to establish the historical SourceSystem baseline used for gap
    detection. Default 30.

.PARAMETER UploadApiAppObjectId
    Optional. Object ID of the Microsoft Entra app registration used for Upload API
    integrations. If supplied, its role assignment at the workspace scope is validated.

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\Sentinel-ThreatIntelAudit-<timestamp>

.EXAMPLE
    .\Get-SentinelThreatIntelAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod"

.EXAMPLE
    .\Get-SentinelThreatIntelAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod" `
        -UploadApiAppObjectId "11111111-2222-3333-4444-555555555555"

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights, Az.Resources modules; authenticated
              Az PowerShell session (Connect-AzAccount) with Log Analytics Reader
              (minimum) on the workspace, and Reader on the Entra app registration if
              -UploadApiAppObjectId is supplied.
    Run As: Any account with the above RBAC — no elevated/admin rights required.
    Safe: Fully read-only. No TI object, ingestion rule, or role assignment is modified.
    Cross-references: Security/Sentinel/ThreatIntelligence-B.md (Fixes 1-5) and
                       ThreatIntelligence-A.md (Playbooks 1-3) for remediation once a
                       gap is identified here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [int]$LookbackHours = 24,

    [int]$SourceSystemLookbackDays = 30,

    [string]$UploadApiAppObjectId,

    [string]$OutputPath = "C:\Temp\Sentinel-ThreatIntelAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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
    param([string]$Category, [string]$Item, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Category = $Category
        Item     = $Item
        Detail   = $Detail
        FoundAt  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    })
}

# ───────────────────────────────────────────────────────────────
# 1. Preflight — resolve workspace
# ───────────────────────────────────────────────────────────────
Write-Status "Resolving workspace $WorkspaceName in $ResourceGroupName..." "INFO"
try {
    $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
    $customerId = $ws.CustomerId
    Write-Status "Workspace resolved (CustomerId: $customerId)" "OK"
} catch {
    Write-Status "Failed to resolve workspace: $($_.Exception.Message)" "ERROR"
    return
}

# ───────────────────────────────────────────────────────────────
# 2. Legacy table dependency check — the headline finding for this topic
# ───────────────────────────────────────────────────────────────
Write-Status "Checking for lingering writes to the retired ThreatIntelligenceIndicator table..." "INFO"
$cutoverDate = Get-Date "2025-07-31"
$legacyQuery = @"
ThreatIntelligenceIndicator
| summarize MaxTimeGenerated = max(TimeGenerated), RowCountSinceCutover = countif(TimeGenerated > datetime(2025-07-31))
"@
try {
    $legacyResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $legacyQuery -ErrorAction Stop
    $row = $legacyResult.Results | Select-Object -First 1
    if ($row -and $row.RowCountSinceCutover -gt 0) {
        Add-Finding -Category "LEGACY_TABLE_STILL_WRITING" -Item "ThreatIntelligenceIndicator" `
            -Detail "MaxTimeGenerated=$($row.MaxTimeGenerated); $($row.RowCountSinceCutover) row(s) newer than the 2025-07-31 cutover. Confirm whether this is a live write (stale integration/TIP connector) or a query artifact, then see ThreatIntelligence-A.md Remediation Playbook 3."
        Write-Status "Legacy table has rows newer than the cutover date — investigate" "WARN"
    } else {
        Write-Status "Legacy table shows no post-cutover activity (expected/healthy)" "OK"
    }
} catch {
    Write-Status "Legacy table query failed (table may not exist in this workspace, which is fine): $($_.Exception.Message)" "WARN"
}

# ───────────────────────────────────────────────────────────────
# 3. Current-schema ingestion volume and per-source gap detection
# ───────────────────────────────────────────────────────────────
Write-Status "Checking current-schema ingestion (ThreatIntelIndicators / ThreatIntelObjects)..." "INFO"
$currentQuery = @"
let lookback = ${LookbackHours}h;
let baseline = ${SourceSystemLookbackDays}d;
let recentIndicators = ThreatIntelIndicators | where TimeGenerated > ago(lookback) | summarize RecentCount = count() by SourceSystem;
let recentObjects = ThreatIntelObjects | where TimeGenerated > ago(lookback) | summarize RecentCount = count() by SourceSystem;
let historicalSources = ThreatIntelIndicators
    | where TimeGenerated > ago(baseline)
    | summarize by SourceSystem
    | union (ThreatIntelObjects | where TimeGenerated > ago(baseline) | summarize by SourceSystem)
    | distinct SourceSystem;
let recentSources = recentIndicators | union recentObjects | summarize RecentTotal = sum(RecentCount) by SourceSystem;
historicalSources
| join kind=leftouter recentSources on SourceSystem
| project SourceSystem, RecentTotal = coalesce(RecentTotal, 0)
"@
try {
    $currentResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $currentQuery -ErrorAction Stop
    $sourceRows = $currentResult.Results

    if (-not $sourceRows -or $sourceRows.Count -eq 0) {
        Add-Finding -Category "NO_CURRENT_TI_INGESTION" -Item "(workspace-wide)" `
            -Detail "No SourceSystem found in ThreatIntelIndicators/ThreatIntelObjects within the $SourceSystemLookbackDays-day baseline window — no TI source appears to have EVER landed data in the current schema for this workspace. Confirm at least one of MDTI/TAXII/Upload API/legacy TIP is actually connected."
        Write-Status "No threat intelligence sources found at all in the baseline window" "WARN"
    } else {
        foreach ($src in $sourceRows) {
            if ([int]$src.RecentTotal -eq 0) {
                Add-Finding -Category "SOURCE_SYSTEM_GAP" -Item $src.SourceSystem `
                    -Detail "Historically active source has zero rows in the last $LookbackHours hours. Check connector auth/consent state, or vendor-side credential rotation for TAXII feeds."
                Write-Status "Source '$($src.SourceSystem)' has gone quiet in the last $LookbackHours hours" "WARN"
            } else {
                Write-Status "Source '$($src.SourceSystem)' actively ingesting ($($src.RecentTotal) rows)" "OK"
            }
        }
    }
} catch {
    Write-Status "Current-schema ingestion query failed: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 4. Upload API Entra app role validation (optional)
# ───────────────────────────────────────────────────────────────
if ($UploadApiAppObjectId) {
    Write-Status "Validating Upload API app role assignment for object $UploadApiAppObjectId..." "INFO"
    try {
        $workspaceResourceId = $ws.ResourceId
        $roleAssignments = Get-AzRoleAssignment -ObjectId $UploadApiAppObjectId -ErrorAction Stop

        $hasCorrectRole = $roleAssignments | Where-Object {
            $_.RoleDefinitionName -eq "Microsoft Sentinel Contributor" -and $_.Scope -eq $workspaceResourceId
        }

        if (-not $hasCorrectRole) {
            $broaderRole = $roleAssignments | Where-Object { $_.RoleDefinitionName -eq "Microsoft Sentinel Contributor" }
            $detail = if ($broaderRole) {
                "App holds 'Microsoft Sentinel Contributor' but NOT at the specific workspace scope ($workspaceResourceId) — found at: $($broaderRole.Scope -join '; '). The Upload API validates workspace-scope specifically; a subscription/resource-group-scoped grant does not satisfy it."
            } else {
                "App does not hold 'Microsoft Sentinel Contributor' at any scope. Grant it at the workspace resource scope: $workspaceResourceId"
            }
            Add-Finding -Category "UPLOAD_API_ROLE_MISSING" -Item $UploadApiAppObjectId -Detail $detail
            Write-Status "Upload API app role misconfigured — see finding detail" "WARN"
        } else {
            Write-Status "Upload API app correctly holds Microsoft Sentinel Contributor at workspace scope" "OK"
        }
    } catch {
        Write-Status "Role assignment check failed: $($_.Exception.Message)" "ERROR"
    }
} else {
    Write-Status "No -UploadApiAppObjectId supplied — skipping Upload API role validation" "INFO"
}

# ───────────────────────────────────────────────────────────────
# 5. Export
# ───────────────────────────────────────────────────────────────
$summaryPath = Join-Path $OutputPath "ThreatIntelAudit-Summary.csv"
$findings | Export-Csv -Path $summaryPath -NoTypeInformation

foreach ($category in ($findings.Category | Select-Object -Unique)) {
    $catPath = Join-Path $OutputPath "ThreatIntelAudit-$category.csv"
    $findings | Where-Object { $_.Category -eq $category } | Export-Csv -Path $catPath -NoTypeInformation
}

Write-Status "Audit complete. $($findings.Count) finding(s) exported to $OutputPath" "OK"
if ($findings.Count -gt 0) {
    Write-Status "Review Security/Sentinel/ThreatIntelligence-B.md (Fixes) or -A.md (Playbooks) for remediation." "INFO"
}
