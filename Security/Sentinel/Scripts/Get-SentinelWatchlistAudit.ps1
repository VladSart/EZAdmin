<#
.SYNOPSIS
    Audits Microsoft Sentinel watchlist health — queryability, item volume against the
    workspace-wide ceiling, SearchKey configuration, and freshness signals.

.DESCRIPTION
    Watchlists fail in ways that are easy to misdiagnose: the documented 28-day
    underlying-table retention is routinely mistaken for a watchlist expiration date, a
    narrow Logs-pane time filter can make a perfectly healthy watchlist look empty, and
    a workspace-wide (not per-watchlist) 10-million-item ceiling means one oversized
    watchlist can silently eat headroom from every other watchlist in the workspace.
    This script surfaces those specific gaps. Flags:
    - WATCHLIST_UNQUERYABLE   : alias returned by _GetWatchlistAlias produces zero rows
                                even with a wide time range — genuine emptiness, not a
                                time-scoping artifact
    - WATCHLIST_NO_SEARCHKEY_SIGNAL : could not confirm a populated SearchKey column
                                (best-effort — the API surface does not expose the
                                SearchKey definition directly; flags watchlists whose
                                data contains no non-null SearchKey values in the sample)
    - WORKSPACE_ITEM_CEILING_RISK : combined active item count across all watchlists in
                                the workspace exceeds -CeilingWarningPct of the documented
                                10,000,000 item ceiling
    - WATCHLIST_LOW_ROW_COUNT : a watchlist has fewer than -MinExpectedRows rows, worth a
                                manual check that this isn't a partial/failed upload

    Exports one CSV per finding category plus a combined summary. Fully read-only — no
    watchlist is created, modified, or deleted.

    Does NOT cover:
    - Data freshness relative to the SOURCE business list (e.g. whether a terminated-
      employee watchlist reflects last week's actual HR data) — this is a process gap,
      not something queryable from Sentinel; see Security/Sentinel/Watchlists-B.md Fix 5
    - Azure Storage SAS-URL upload path validation (no API surface exposes the SAS
      token/expiry used for a given watchlist's original upload)
    - Portal/API 5XX service-incident detection (point-in-time service health is not a
      workspace-queryable property — check Azure Service Health directly)

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace that Sentinel is enabled on.

.PARAMETER MinExpectedRows
    Minimum row count below which a watchlist is flagged for manual review as a possible
    partial/failed upload. Default 1 (flags genuinely empty watchlists only; raise this
    for environments where every legitimate watchlist is expected to be larger).

.PARAMETER CeilingWarningPct
    Percentage of the documented 10,000,000 workspace-wide active-item ceiling at which
    to raise a capacity-risk finding. Default 70.

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\Sentinel-WatchlistAudit-<timestamp>

.EXAMPLE
    .\Get-SentinelWatchlistAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod"

.EXAMPLE
    .\Get-SentinelWatchlistAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod" `
        -CeilingWarningPct 50 -MinExpectedRows 5

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights modules; authenticated Az PowerShell
              session (Connect-AzAccount) with Log Analytics Reader (minimum) on the
              workspace.
    Run As: Any account with the above RBAC — no elevated/admin rights required.
    Safe: Fully read-only. No watchlist is created, modified, or deleted. Queries always
          use a deliberately wide time range (see -QueryLookbackDays) specifically to
          avoid the narrow-time-scope false-empty pattern this topic's runbooks warn
          about — do not narrow this without reading Watchlists-B.md Diagnosis Step 2 first.
    Cross-references: Security/Sentinel/Watchlists-B.md (Fixes 1-6) and Watchlists-A.md
                       (Playbooks 1-3) for remediation once a gap is identified here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [int]$MinExpectedRows = 1,

    [int]$CeilingWarningPct = 70,

    [int]$QueryLookbackDays = 60,

    [string]$OutputPath = "C:\Temp\Sentinel-WatchlistAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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
$WorkspaceItemCeiling = 10000000

function Add-Finding {
    param([string]$Category, [string]$WatchlistAlias, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Category       = $Category
        WatchlistAlias = $WatchlistAlias
        Detail         = $Detail
        FoundAt        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
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
# 2. Enumerate all watchlists
# ───────────────────────────────────────────────────────────────
Write-Status "Enumerating watchlist aliases..." "INFO"
$aliases = @()
try {
    $aliasResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query "_GetWatchlistAlias" -ErrorAction Stop
    $aliases = $aliasResult.Results | Select-Object -ExpandProperty AliasName -ErrorAction SilentlyContinue
    if (-not $aliases) {
        # Fallback in case the function's output column name differs by API version
        $aliases = $aliasResult.Results | ForEach-Object { $_.PSObject.Properties.Value } | Select-Object -First 50
    }
    Write-Status "Found $($aliases.Count) watchlist(s)" "OK"
} catch {
    Write-Status "Failed to enumerate watchlist aliases: $($_.Exception.Message)" "ERROR"
    return
}

if (-not $aliases -or $aliases.Count -eq 0) {
    Write-Status "No watchlists found in this workspace — nothing further to audit" "WARN"
}

# ───────────────────────────────────────────────────────────────
# 3. Per-watchlist queryability, row count, and SearchKey sanity check
#    (deliberately wide lookback — see .NOTES on the narrow-time-scope false-empty pattern)
# ───────────────────────────────────────────────────────────────
$totalItemCount = 0

foreach ($alias in $aliases) {
    Write-Status "Checking watchlist '$alias'..." "INFO"
    $perWatchlistQuery = @"
_GetWatchlist('$alias')
| where TimeGenerated > ago(${QueryLookbackDays}d)
| summarize RowCount = count(), NonNullSearchKeyCount = countif(isnotempty(SearchKey))
"@
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $perWatchlistQuery -ErrorAction Stop
        $row = $result.Results | Select-Object -First 1

        if (-not $row -or [int]$row.RowCount -eq 0) {
            Add-Finding -Category "WATCHLIST_UNQUERYABLE" -WatchlistAlias $alias `
                -Detail "Zero rows even with a $QueryLookbackDays-day lookback — this is a genuine emptiness signal, not the narrow-time-scope false-negative this topic's runbook warns about (that lookback is already wide). Confirm the original upload actually completed."
            Write-Status "'$alias' returned zero rows at $QueryLookbackDays-day lookback" "WARN"
            continue
        }

        $rowCount = [int]$row.RowCount
        $totalItemCount += $rowCount

        if ($rowCount -lt $MinExpectedRows) {
            Add-Finding -Category "WATCHLIST_LOW_ROW_COUNT" -WatchlistAlias $alias `
                -Detail "Row count ($rowCount) is below -MinExpectedRows ($MinExpectedRows) — worth a manual check that the original CSV upload wasn't partial/truncated."
            Write-Status "'$alias' has a low row count ($rowCount) — flagged for review" "WARN"
        }

        if ([int]$row.NonNullSearchKeyCount -eq 0) {
            Add-Finding -Category "WATCHLIST_NO_SEARCHKEY_SIGNAL" -WatchlistAlias $alias `
                -Detail "No non-null SearchKey values found in $rowCount sampled row(s). Either this watchlist's SearchKey column is genuinely sparse/unset in the source data, or consuming queries joining on SearchKey specifically will under-match — confirm the intended join column against the watchlist's actual definition in the portal."
            Write-Status "'$alias' shows no populated SearchKey values — verify join pattern" "WARN"
        } else {
            Write-Status "'$alias': $rowCount row(s), SearchKey populated" "OK"
        }
    } catch {
        Write-Status "Query failed for '$alias': $($_.Exception.Message)" "ERROR"
    }
}

# ───────────────────────────────────────────────────────────────
# 4. Workspace-wide item ceiling check
# ───────────────────────────────────────────────────────────────
$ceilingThreshold = $WorkspaceItemCeiling * ($CeilingWarningPct / 100)
Write-Status "Combined sampled item count across all watchlists: $totalItemCount (workspace ceiling: $WorkspaceItemCeiling)" "INFO"
if ($totalItemCount -ge $ceilingThreshold) {
    Add-Finding -Category "WORKSPACE_ITEM_CEILING_RISK" -WatchlistAlias "(workspace-wide)" `
        -Detail "Combined sampled watchlist item count ($totalItemCount) has crossed $CeilingWarningPct% of the documented 10,000,000 workspace-wide active-item ceiling. Note: this figure is a SAMPLE within the $QueryLookbackDays-day lookback and Sentinel's actual active-item count may differ — treat this as an early warning to review watchlist sizing, not an authoritative capacity number. See Watchlists-A.md Remediation Playbook 1 (migrate oversized watchlists to a custom log table)."
    Write-Status "Approaching the workspace-wide watchlist item ceiling — review sizing" "WARN"
} else {
    Write-Status "Well within the workspace-wide item ceiling" "OK"
}

# ───────────────────────────────────────────────────────────────
# 5. Export
# ───────────────────────────────────────────────────────────────
$summaryPath = Join-Path $OutputPath "WatchlistAudit-Summary.csv"
$findings | Export-Csv -Path $summaryPath -NoTypeInformation

foreach ($category in ($findings.Category | Select-Object -Unique)) {
    $catPath = Join-Path $OutputPath "WatchlistAudit-$category.csv"
    $findings | Where-Object { $_.Category -eq $category } | Export-Csv -Path $catPath -NoTypeInformation
}

Write-Status "Audit complete. $($findings.Count) finding(s) exported to $OutputPath" "OK"
if ($findings.Count -gt 0) {
    Write-Status "Review Security/Sentinel/Watchlists-B.md (Fixes) or -A.md (Playbooks) for remediation." "INFO"
}
