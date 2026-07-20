<#
.SYNOPSIS
    Audits Microsoft Sentinel UEBA (User & Entity Behavior Analytics) health for a
    given Log Analytics workspace: core table data flow, directory-sync completeness,
    BlastRadius/peer-group data-hygiene gaps, and resource-lock blockers.

.DESCRIPTION
    UEBA is three independently-toggled capabilities (base UEBA, Detect Anomalies,
    UEBA behaviors layer) that share one settings area, and none of the three toggle
    states are reliably exposed as a queryable resource property as of this writing —
    this script therefore audits by table content and known prerequisite blockers
    rather than by reading a toggle flag directly, and says so in its own output.
    Flags:
    - RESOURCE_LOCK_PRESENT       : a lock on the resource group that would silently
                                    block (re-)enabling UEBA
    - TABLE_NO_DATA               : one of BehaviorAnalytics/IdentityInfo/
                                    UserPeerAnalytics/Anomalies has zero rows in the
                                    lookback window
    - TABLE_STALE                 : a table has historical data but nothing in the
                                    last -StaleDays (possible data-flow stall — see
                                    UEBA-B.md Fix 2)
    - IDENTITY_SYNC_LOW_COVERAGE  : IdentityInfo distinct-user count is below
                                    -MinExpectedUsers, suggesting incomplete directory
                                    sync (only relevant if you know the tenant's
                                    approximate headcount — pass 0 to skip this check)
    - BLASTRADIUS_MANAGER_GAP     : percentage of IdentityInfo users missing the
                                    Manager attribute exceeds -ManagerGapThresholdPct
                                    (BlastRadius cannot calculate without it)
    - ANOMALIES_EMPTY_LIKELY_TOGGLE_OFF : BehaviorAnalytics is healthy but Anomalies
                                    is completely empty — the most common real-world
                                    "UEBA doesn't work" report, usually the separate
                                    Detect Anomalies toggle being off rather than a
                                    genuine fault

    Exports one CSV per finding category plus a combined summary. Fully read-only —
    no UEBA setting, data source, or identity attribute is created, modified, enabled,
    or deleted.

    Does NOT cover:
    - Reading the actual on/off state of the UEBA / Detect Anomalies / behaviors-layer
      toggles directly (no public Az PowerShell cmdlet exposes these as of this
      writing) — this script infers likely state from table content instead, and
      that inference is documented per-finding rather than presented as certain
    - On-premises AD / Microsoft Defender for Identity sensor health (see
      Security/Defender/ for MDI-specific tooling)
    - UEBA behaviors layer table checks (SentinelBehaviorInfo/SentinelBehaviorEntities)
      — a newer Preview capability with its own separate enablement flow; add in a
      future revision once that surface stabilizes

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace that Sentinel/UEBA is enabled on.

.PARAMETER LookbackDays
    Days of history to evaluate for table population checks. Default 14.

.PARAMETER StaleDays
    If a table has historical rows older than this but nothing within it, flag as
    possibly stalled. Default 3.

.PARAMETER MinExpectedUsers
    Approximate tenant user headcount, used only to flag a suspiciously low
    IdentityInfo distinct-user count. Pass 0 to skip this check entirely (default),
    since an incorrect estimate produces noise rather than signal.

.PARAMETER ManagerGapThresholdPct
    Percentage of IdentityInfo users missing the Manager attribute above which a
    BlastRadius data-hygiene finding is raised. Default 30.

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\Sentinel-UEBAAudit-<timestamp>

.EXAMPLE
    .\Get-SentinelUEBAAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod"

.EXAMPLE
    .\Get-SentinelUEBAAudit.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod" `
        -MinExpectedUsers 450 -ManagerGapThresholdPct 20

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights, Az.Resources modules; authenticated
              Az PowerShell session (Connect-AzAccount) with Microsoft Sentinel Reader
              (minimum) plus Reader on the resource group (for the lock check).
    Run As: Any account with the above RBAC — no elevated/admin rights required.
    Safe: Fully read-only. No UEBA configuration, data source, or identity attribute
          is modified.
    Cross-references: Security/Sentinel/UEBA-B.md (Fixes 1-7) and UEBA-A.md
                       (Playbooks 1-4) for remediation once a gap is identified here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [int]$LookbackDays = 14,

    [int]$StaleDays = 3,

    [int]$MinExpectedUsers = 0,

    [int]$ManagerGapThresholdPct = 30,

    [string]$OutputPath = "C:\Temp\Sentinel-UEBAAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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
    param([string]$Category, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Category = $Category
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
    Write-Status "FATAL: could not resolve workspace — $($_.Exception.Message)" "ERROR"
    return
}

# ───────────────────────────────────────────────────────────────
# 2. Detect — resource lock blocking (re-)enable
# ───────────────────────────────────────────────────────────────
Write-Status "Checking for resource locks on $ResourceGroupName..." "INFO"
try {
    $locks = Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    $locks | Select-Object Name, LockId, Properties | Export-Csv "$OutputPath\01-ResourceLocks.csv" -NoTypeInformation
    if ($locks.Count -gt 0) {
        foreach ($lock in $locks) {
            Add-Finding -Category "RESOURCE_LOCK_PRESENT" `
                -Detail "Lock '$($lock.Name)' present on resource group — would silently block a UEBA (re-)enable attempt if it covers the workspace."
        }
        Write-Status "  $($locks.Count) lock(s) found" "WARN"
    } else {
        Write-Status "  No resource locks found" "OK"
    }
} catch {
    Write-Status "Resource lock check failed: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 3. Detect — core UEBA table population and staleness
# ───────────────────────────────────────────────────────────────
Write-Status "Checking UEBA table health (BehaviorAnalytics, IdentityInfo, UserPeerAnalytics, Anomalies)..." "INFO"

$tableResults = @{}
try {
    $tableQuery = @"
union isfuzzy=true
  (BehaviorAnalytics | where TimeGenerated > ago(${LookbackDays}d) | summarize Table="BehaviorAnalytics", Count=count(), Last=max(TimeGenerated)),
  (IdentityInfo | where TimeGenerated > ago(${LookbackDays}d) | summarize Table="IdentityInfo", Count=count(), Last=max(TimeGenerated)),
  (UserPeerAnalytics | where TimeGenerated > ago(${LookbackDays}d) | summarize Table="UserPeerAnalytics", Count=count(), Last=max(TimeGenerated)),
  (Anomalies | where TimeGenerated > ago(${LookbackDays}d) | summarize Table="Anomalies", Count=count(), Last=max(TimeGenerated))
"@
    $tableHealth = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $tableQuery -ErrorAction Stop
    $tableHealth.Results | Export-Csv "$OutputPath\02-TableHealth.csv" -NoTypeInformation

    foreach ($row in $tableHealth.Results) {
        $tableResults[$row.Table] = $row
        if ([int]$row.Count -eq 0) {
            Add-Finding -Category "TABLE_NO_DATA" `
                -Detail "$($row.Table) has zero rows in the last $LookbackDays day(s). Either the corresponding toggle was never enabled, or (for tables under ~1 week old) baseline period hasn't elapsed yet."
        } elseif ($row.Last) {
            $lastSeen = [datetime]$row.Last
            $daysSince = (Get-Date).ToUniversalTime() - $lastSeen.ToUniversalTime()
            if ($daysSince.TotalDays -gt $StaleDays) {
                Add-Finding -Category "TABLE_STALE" `
                    -Detail "$($row.Table) has $($row.Count) historical row(s) but nothing in the last $([math]::Round($daysSince.TotalDays,1)) day(s) (threshold: $StaleDays). Possible data-flow stall — see UEBA-B.md Fix 2 (disable/re-enable workaround)."
            }
        }
    }
    Write-Status "  Table health query complete" "OK"
} catch {
    Write-Status "UEBA table health query failed: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 4. Detect — the single most common real-world report: BehaviorAnalytics
#    healthy but Anomalies empty (Detect Anomalies toggle likely off)
# ───────────────────────────────────────────────────────────────
if ($tableResults.ContainsKey("BehaviorAnalytics") -and $tableResults.ContainsKey("Anomalies")) {
    $baHealthy = [int]$tableResults["BehaviorAnalytics"].Count -gt 0
    $anomEmpty = [int]$tableResults["Anomalies"].Count -eq 0
    if ($baHealthy -and $anomEmpty) {
        Add-Finding -Category "ANOMALIES_EMPTY_LIKELY_TOGGLE_OFF" `
            -Detail "BehaviorAnalytics has data but Anomalies is completely empty. Base UEBA and Detect Anomalies are independent toggles — confirm Detect Anomalies is on before assuming a fault (see UEBA-B.md Fix 3)."
        Write-Status "  BehaviorAnalytics healthy, Anomalies empty — likely Detect Anomalies toggle off" "WARN"
    }
}

# ───────────────────────────────────────────────────────────────
# 5. Detect — identity sync coverage and BlastRadius/Manager gap
# ───────────────────────────────────────────────────────────────
Write-Status "Checking IdentityInfo coverage and Manager-attribute completeness..." "INFO"
try {
    $identityQuery = @"
IdentityInfo
| where TimeGenerated > ago(${LookbackDays}d)
| summarize Total = dcount(AccountObjectId), MissingManager = dcountif(AccountObjectId, isempty(Manager))
"@
    $identityResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $identityQuery -ErrorAction Stop
    $identityResult.Results | Export-Csv "$OutputPath\03-IdentityCoverage.csv" -NoTypeInformation

    if ($identityResult.Results.Count -gt 0) {
        $total = [int]$identityResult.Results[0].Total
        $missingMgr = [int]$identityResult.Results[0].MissingManager

        if ($MinExpectedUsers -gt 0 -and $total -lt $MinExpectedUsers) {
            Add-Finding -Category "IDENTITY_SYNC_LOW_COVERAGE" `
                -Detail "IdentityInfo shows $total distinct user(s), below the expected minimum of $MinExpectedUsers. Directory sync may be incomplete, or on-prem AD sync isn't reaching UEBA (check MDI sensor health)."
        }

        if ($total -gt 0) {
            $gapPct = [math]::Round((100.0 * $missingMgr / $total), 1)
            if ($gapPct -ge $ManagerGapThresholdPct) {
                Add-Finding -Category "BLASTRADIUS_MANAGER_GAP" `
                    -Detail "$gapPct% of synced identities ($missingMgr of $total) are missing the Manager attribute (threshold: $ManagerGapThresholdPct%). BlastRadius cannot calculate for these users — identity-hygiene remediation needed in Entra ID, not a Sentinel-side fix."
            }
        }
        Write-Status "  Identity coverage: $total user(s), $missingMgr missing Manager" "OK"
    }
} catch {
    Write-Status "Identity coverage query failed: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 6. Report — combined findings + console summary
# ───────────────────────────────────────────────────────────────
$findings | Export-Csv "$OutputPath\00-AllFindings.csv" -NoTypeInformation

Write-Host "`n=== Sentinel UEBA Audit Summary ===" -ForegroundColor Cyan
Write-Host "Workspace: $WorkspaceName | Lookback: $LookbackDays day(s)" -ForegroundColor Cyan
Write-Host "NOTE: this script infers toggle state from table content — it cannot read the UEBA/" -ForegroundColor Cyan
Write-Host "Detect Anomalies/behaviors-layer switches directly (no public cmdlet exposes them)." -ForegroundColor Cyan

if ($findings.Count -eq 0) {
    Write-Status "No findings — all core UEBA tables populated, no resource locks, identity sync healthy." "OK"
} else {
    $findings | Group-Object Category | ForEach-Object {
        Write-Status "$($_.Name): $($_.Count) finding(s)" "WARN"
    }
    $findings | Format-Table Category, Detail -Wrap -AutoSize
}

Write-Status "Full results exported to: $OutputPath" "OK"
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Status "Zipped to: $OutputPath.zip" "OK"
