<#
.SYNOPSIS
    Tenant-wide audit of Exchange Online transport rules (ETRs) for the conflict patterns documented in
    TransportRules-B.md and TransportRules-A.md — stuck test-mode rules, priority short-circuits,
    condition/exception logic risks, and DLP overlap.

.DESCRIPTION
    Reads every transport rule in priority order and flags:

    - STUCK_IN_TEST_MODE     Rule.Mode is Test or AuditAndNotify, not Enforce — actions never apply.
                             Flagged with an age check: rules older than -StaleTestModeDays in this state
                             are almost certainly a forgotten staging rule, not an intentional audit-only rule.
    - SHORT_CIRCUITED        A lower-priority-number (earlier-evaluated) enabled rule has
                             StopRuleProcessing = $true — every rule below it in priority is unreachable
                             for any message that rule also matches. Reports the specific blocking rule.
    - BROAD_OR_CONDITION     A single condition property (e.g. SenderDomainIs, RecipientDomainIs) has more
                             than -BroadConditionThreshold values ORed together — a common sign of scope
                             creep from repeated small edits rather than a deliberate design.
    - NO_EXCEPTION_SCOPE     A rule with a Reject/Redirect/Quarantine/Delete action has zero Exceptions
                             defined at all — the highest-blast-radius action combined with the least
                             scoping, per TransportRules-A.md's "stage every non-trivial change" guidance.
    - DISABLED_WITH_HISTORY  A currently-disabled rule that was Enabled within the lookback window per
                             Search-UnifiedAuditLog — flags rules that may have been disabled as a quick
                             fix and forgotten, rather than intentionally retired.
    - DLP_OVERLAP_RISK       An enabled ETR whose SenderDomainIs/RecipientDomainIs/scope conditions overlap
                             with an enabled DLP policy's evaluated scope (best-effort name/domain heuristic
                             — always confirm manually per TransportRules-A.md Fix 6 / Playbook 3, this
                             cannot fully replace reading both rule definitions).

    Read-only. Does not modify, reorder, enable/disable, or delete any rule — see TransportRules-B.md
    Common Fix Paths / TransportRules-A.md Remediation Playbooks for the corresponding fixes once a
    flagged rule is confirmed.

.PARAMETER StaleTestModeDays
    Age (in days, based on WhenChanged) beyond which a Test/AuditAndNotify rule is flagged
    STUCK_IN_TEST_MODE with elevated severity rather than informational. Default: 14.

.PARAMETER BroadConditionThreshold
    Number of OR'd values within a single condition property above which a rule is flagged
    BROAD_OR_CONDITION. Default: 5.

.PARAMETER AuditLookbackDays
    Days of Search-UnifiedAuditLog history to check for DISABLED_WITH_HISTORY and general
    recent-change context. Default: 30. Requires Compliance Administrator / View-Only Audit Logs role.

.PARAMETER SkipDlpCheck
    Switch. Skip the DLP overlap heuristic (Get-DlpCompliancePolicy/Get-DlpComplianceRule require
    Purview compliance permissions that may not be present in every session).

.PARAMETER OutputPath
    Path for CSV export of the full per-rule audit. Defaults to
    .\TransportRuleConflictAudit_<timestamp>.csv in the current directory.

.EXAMPLE
    .\Get-TransportRuleConflictAudit.ps1

.EXAMPLE
    .\Get-TransportRuleConflictAudit.ps1 -StaleTestModeDays 7 -BroadConditionThreshold 3 -SkipDlpCheck

.NOTES
    Requires: ExchangeOnlineManagement module, connected via Connect-ExchangeOnline.
    Optional: Compliance Administrator role for Search-UnifiedAuditLog and DLP cmdlets — script degrades
              gracefully (skips those checks with a warning) if not available.
    Safe: Yes — fully read-only. No New-/Set-/Remove-/Enable-/Disable-TransportRule calls anywhere.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$StaleTestModeDays = 14,

    [Parameter(Mandatory = $false)]
    [int]$BroadConditionThreshold = 5,

    [Parameter(Mandatory = $false)]
    [int]$AuditLookbackDays = 30,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDlpCheck,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\TransportRuleConflictAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

# ---------------------------------------------------------------------------
# PREFLIGHT
# ---------------------------------------------------------------------------
Write-Status "===== PREFLIGHT =====" "OK"
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Status "Module 'ExchangeOnlineManagement' not found. Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser" "ERROR"
    throw "Missing required module: ExchangeOnlineManagement"
}
Import-Module ExchangeOnlineManagement -ErrorAction Stop

try {
    $exoSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
    if (-not $exoSession) {
        Write-Status "Not connected to Exchange Online. Connecting..." "WARN"
        Connect-ExchangeOnline -ShowBanner:$false | Out-Null
    }
    else {
        Write-Status "Connected to Exchange Online." "OK"
    }
}
catch {
    Write-Status "Failed to establish Exchange Online connection: $($_.Exception.Message)" "ERROR"
    throw
}

$auditAvailable = $true
try {
    Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-1) -EndDate (Get-Date) -ResultSize 1 -ErrorAction Stop | Out-Null
    Write-Status "Unified Audit Log access confirmed." "OK"
}
catch {
    $auditAvailable = $false
    Write-Status "Search-UnifiedAuditLog not available in this session — DISABLED_WITH_HISTORY check will be skipped: $($_.Exception.Message)" "WARN"
}

$dlpAvailable = $false
if (-not $SkipDlpCheck) {
    try {
        Get-DlpCompliancePolicy -ErrorAction Stop | Out-Null
        $dlpAvailable = $true
        Write-Status "DLP compliance cmdlets available — DLP_OVERLAP_RISK check enabled." "OK"
    }
    catch {
        Write-Status "DLP compliance cmdlets not available in this session — DLP_OVERLAP_RISK check will be skipped: $($_.Exception.Message)" "WARN"
    }
}
else {
    Write-Status "Skipping DLP overlap check (-SkipDlpCheck specified)." "INFO"
}

# ---------------------------------------------------------------------------
# COLLECT
# ---------------------------------------------------------------------------
Write-Status "===== COLLECTING TRANSPORT RULES =====" "OK"
$allRules = Get-TransportRule | Sort-Object Priority
Write-Status "Found $($allRules.Count) transport rules ($(($allRules | Where-Object State -eq 'Enabled').Count) enabled)." "OK"

$dlpRules = @()
if ($dlpAvailable) {
    try {
        $dlpRules = Get-DlpComplianceRule | Where-Object { -not $_.Disabled }
        Write-Status "Found $($dlpRules.Count) enabled DLP rules for overlap comparison." "OK"
    }
    catch {
        Write-Status "Failed to enumerate DLP rules — continuing without DLP_OVERLAP_RISK: $($_.Exception.Message)" "WARN"
        $dlpAvailable = $false
    }
}

$recentAuditOps = @()
if ($auditAvailable) {
    Write-Status "Querying $AuditLookbackDays days of transport rule change history..." "INFO"
    try {
        $recentAuditOps = Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-$AuditLookbackDays) -EndDate (Get-Date) `
            -Operations "New-TransportRule", "Set-TransportRule", "Remove-TransportRule", "Enable-TransportRule", "Disable-TransportRule" `
            -ResultSize 5000 -ErrorAction Stop
        Write-Status "Retrieved $($recentAuditOps.Count) transport rule change events." "OK"
    }
    catch {
        Write-Status "Failed to retrieve audit log entries: $($_.Exception.Message)" "WARN"
        $auditAvailable = $false
    }
}

# ---------------------------------------------------------------------------
# ANALYSE
# ---------------------------------------------------------------------------
Write-Status "===== ANALYSING =====" "OK"

$results = New-Object System.Collections.Generic.List[object]
$enabledRules = $allRules | Where-Object { $_.State -eq "Enabled" }
$now = Get-Date

# High-blast-radius action keywords to check against Actions text
$highImpactActionPattern = 'RejectMessage|DeleteMessage|RedirectMessage|Quarantine'

foreach ($rule in $allRules) {

    $flags = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]

    # --- STUCK_IN_TEST_MODE ---
    if ($rule.State -eq "Enabled" -and $rule.Mode -in @("Test", "AuditAndNotify")) {
        $ageDays = $null
        if ($rule.WhenChanged) { $ageDays = [math]::Round(($now - $rule.WhenChanged).TotalDays, 1) }
        if ($null -ne $ageDays -and $ageDays -ge $StaleTestModeDays) {
            $flags.Add("STUCK_IN_TEST_MODE")
            $notes.Add("Mode=$($rule.Mode) for $ageDays days (threshold $StaleTestModeDays) — likely forgotten staging rule")
        }
        else {
            $flags.Add("IN_TEST_MODE_RECENT")
            $notes.Add("Mode=$($rule.Mode), changed $ageDays day(s) ago — may still be intentional staging")
        }
    }

    # --- SHORT_CIRCUITED ---
    if ($rule.State -eq "Enabled") {
        $blockers = $enabledRules | Where-Object {
            $_.Priority -lt $rule.Priority -and $_.StopRuleProcessing -eq $true -and $_.Mode -eq "Enforce"
        }
        if ($blockers.Count -gt 0) {
            $flags.Add("SHORT_CIRCUITED_RISK")
            $blockerNames = ($blockers | Select-Object -ExpandProperty Name) -join "; "
            $notes.Add("Higher-priority StopRuleProcessing rule(s) may pre-empt this one: $blockerNames")
        }
    }

    # --- BROAD_OR_CONDITION ---
    $conditionsText = if ($rule.Conditions) { $rule.Conditions.ToString() } else { "" }
    # Heuristic: count comma-separated items inside the first bracketed/quoted list found per condition line
    $broadMatches = [regex]::Matches($conditionsText, "'[^']+'(?:,\s*'[^']+')+")
    foreach ($m in $broadMatches) {
        $valueCount = ($m.Value -split ",").Count
        if ($valueCount -gt $BroadConditionThreshold) {
            $flags.Add("BROAD_OR_CONDITION")
            $notes.Add("Condition contains $valueCount OR'd values (threshold $BroadConditionThreshold) — review for scope creep")
            break
        }
    }

    # --- NO_EXCEPTION_SCOPE ---
    $actionsText = if ($rule.Actions) { $rule.Actions.ToString() } else { "" }
    $hasHighImpactAction = $actionsText -match $highImpactActionPattern
    $hasExceptions = [bool]($rule.Exceptions -and $rule.Exceptions.ToString().Trim().Length -gt 0)
    if ($rule.State -eq "Enabled" -and $hasHighImpactAction -and -not $hasExceptions) {
        $flags.Add("NO_EXCEPTION_SCOPE")
        $notes.Add("High-impact action ($([regex]::Match($actionsText,$highImpactActionPattern).Value)) with zero exceptions defined")
    }

    # --- DISABLED_WITH_HISTORY ---
    if ($rule.State -eq "Disabled" -and $auditAvailable) {
        $relevantOps = $recentAuditOps | Where-Object { $_.AuditData -match [regex]::Escape($rule.Name) }
        $enableThenDisable = $relevantOps | Where-Object { $_.Operations -eq "Disable-TransportRule" }
        if ($enableThenDisable.Count -gt 0) {
            $flags.Add("DISABLED_WITH_HISTORY")
            $notes.Add("Disabled within last $AuditLookbackDays days ($($enableThenDisable.Count) Disable-TransportRule event(s) found) — confirm intentional retirement")
        }
    }

    # --- DLP_OVERLAP_RISK (best-effort heuristic) ---
    if ($dlpAvailable -and $rule.State -eq "Enabled" -and $dlpRules.Count -gt 0) {
        # Very coarse heuristic: flag for manual review if the ETR has any domain/recipient scoping
        # at all, since we cannot cheaply cross-reference DLP's sensitive-info-type scope from here.
        if ($conditionsText -match "DomainIs|RecipientAddressContainsWords|SentTo") {
            $flags.Add("DLP_OVERLAP_RISK_REVIEW")
            $notes.Add("Tenant has $($dlpRules.Count) enabled DLP rule(s) — manually confirm no scope overlap per TransportRules-A.md Playbook 3")
        }
    }

    if ($flags.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Priority           = $rule.Priority
            Name               = $rule.Name
            State              = $rule.State
            Mode               = $rule.Mode
            StopRuleProcessing = $rule.StopRuleProcessing
            WhenChanged        = $rule.WhenChanged
            Flags              = ($flags -join "; ")
            Notes              = ($notes -join " | ")
        })
    }
}

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
Write-Status "===== SUMMARY =====" "OK"
Write-Status "Total rules: $($allRules.Count) | Enabled: $($enabledRules.Count) | Flagged: $($results.Count)" "INFO"

if ($results.Count -eq 0) {
    Write-Status "No conflict patterns detected." "OK"
}
else {
    $results | Sort-Object Priority | Format-Table Priority, Name, Mode, Flags -AutoSize -Wrap

    $severe = $results | Where-Object { $_.Flags -match "STUCK_IN_TEST_MODE|SHORT_CIRCUITED_RISK|NO_EXCEPTION_SCOPE" }
    if ($severe.Count -gt 0) {
        Write-Status "$($severe.Count) rule(s) flagged with high-priority issues (stuck test mode, short-circuit risk, or unscoped high-impact action). Review these first." "WARN"
    }
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "Full results exported to: $OutputPath" "OK"

Write-Status "===== DONE =====" "OK"
Write-Status "Read-only audit complete. No rules were modified, reordered, enabled, or disabled." "INFO"
