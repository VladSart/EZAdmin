<#
.SYNOPSIS
    Audits Purview DLP and auto-labeling policy state for a Defender for Cloud
    Apps (MDA) File Policy Retirement migration project (retirement date:
    January 6, 2027).

.DESCRIPTION
    MDA File policy inventory, migration-wizard verdicts (Can migrate/Partial
    migration/Cannot migrate), and per-policy Notes are Defender-portal-only
    data with no Graph or PowerShell read surface — this script does NOT
    attempt to enumerate them. What it DOES do is give you a fast, scriptable
    view of the Purview side of the migration once policies start landing
    there, so a migration project spanning many policies can be tracked
    without manually opening each one in the portal:

      - Every DLP policy whose name matches the migration tool's naming
        convention ("[Migrated] <original name> (1P DLP)"), plus any policy
        name you explicitly include via -AdditionalNamePattern for manually
        recreated policies that don't follow that convention
      - Current Mode (Test with notifications / TestWithoutNotifications / On)
        for each, so you can see at a glance which migrated policies are
        still sitting in the mandatory post-migration test state
      - Auto-labeling policies matching the same filters (a separate cmdlet
        family — these are never touched by the migration tool and are
        always manually created)
      - A flag for any policy inactive for longer than -StaleValidationDays
        while still in a test mode, as a signal that validation may have
        stalled and enforcement cutover (Phase 5 in FilePolicyRetirement-A.md)
        is overdue for a decision either way

    Run this periodically during a migration project rather than as a one-off
    — the useful signal is watching the Test-mode count trend toward zero as
    validated policies get cut over to enforcing.

.PARAMETER NamePattern
    Wildcard pattern used to find migrated/candidate policies. Defaults to the
    migration tool's own naming convention.

.PARAMETER AdditionalNamePattern
    Optional second wildcard pattern to also match manually recreated policies
    that don't follow the tool's naming convention (e.g. a naming standard
    your team uses for hand-built auto-labeling or non-Microsoft-app policies).

.PARAMETER StaleValidationDays
    Number of days a policy can sit unchanged in a test mode before being
    flagged as a stalled-validation candidate. Default 30.

.EXAMPLE
    .\Get-FilePolicyRetirementAudit.ps1

    Runs with default settings against the migration tool's standard naming
    convention.

.EXAMPLE
    .\Get-FilePolicyRetirementAudit.ps1 -AdditionalNamePattern "*FilePolicy-Manual*" -StaleValidationDays 14

    Also picks up manually recreated policies following a custom naming
    standard, and flags stalled test-mode policies after 14 days instead of 30.

.NOTES
    Requires the Exchange Online Management module (for Connect-IPPSSession)
    — Purview DLP and auto-labeling cmdlets live in Security & Compliance
    PowerShell, not Microsoft.Graph. Read-only; makes no configuration changes.
    Requires a role with Purview DLP/auto-labeling read access (e.g.
    Compliance Administrator, Compliance Data Administrator, or Global Reader).
#>

[CmdletBinding()]
param(
    [string]$NamePattern = "*[Migrated]*(1P DLP)*",
    [string]$AdditionalNamePattern,
    [int]$StaleValidationDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----------------------------------------------------------
Write-Status "Connecting to Security & Compliance PowerShell (Connect-IPPSSession)..."
try {
    Connect-IPPSSession -ErrorAction Stop | Out-Null
    Write-Status "Connected." "OK"
}
catch {
    Write-Status "Connect-IPPSSession failed: $($_.Exception.Message)" "ERROR"
    Write-Status "Confirm the Exchange Online Management module is installed (Install-Module ExchangeOnlineManagement) and that this account holds Compliance Administrator, Compliance Data Administrator, or Global Reader." "WARN"
    throw
}

$results = [System.Collections.Generic.List[object]]::new()
$today = Get-Date

# ---- Detect: DLP policies -------------------------------------------------
Write-Status "Querying DLP compliance policies matching '$NamePattern'..."
$dlpPolicies = Get-DlpCompliancePolicy | Where-Object { $_.Name -like $NamePattern }

if ($AdditionalNamePattern) {
    Write-Status "Also querying DLP compliance policies matching '$AdditionalNamePattern'..."
    $dlpPolicies += Get-DlpCompliancePolicy | Where-Object { $_.Name -like $AdditionalNamePattern }
}
$dlpPolicies = $dlpPolicies | Sort-Object Name -Unique

foreach ($p in $dlpPolicies) {
    $daysSinceChange = if ($p.WhenChanged) { ($today - $p.WhenChanged).Days } else { $null }
    $inTestMode = $p.Mode -in @("TestWithNotifications", "TestWithoutNotifications", "Test")
    $stale = $inTestMode -and $daysSinceChange -ne $null -and $daysSinceChange -ge $StaleValidationDays

    $results.Add([PSCustomObject]@{
        PolicyType        = "DLP"
        Name              = $p.Name
        Mode              = $p.Mode
        Enabled           = $p.Enabled
        Workload          = ($p.Workload -join ", ")
        WhenCreated       = $p.WhenCreated
        WhenChanged       = $p.WhenChanged
        DaysSinceChange   = $daysSinceChange
        InTestMode        = $inTestMode
        StaleValidation   = $stale
        Severity          = if ($stale) { "WARN - validation may be stalled" }
                             elseif ($inTestMode) { "INFO - awaiting cutover decision" }
                             else { "OK - enforcing" }
    })
}

# ---- Detect: auto-labeling policies (separate cmdlet family) --------------
Write-Status "Querying auto-labeling policies matching '$NamePattern'..."
$labelPolicies = Get-AutoSensitivityLabelPolicy | Where-Object { $_.Name -like $NamePattern }

if ($AdditionalNamePattern) {
    $labelPolicies += Get-AutoSensitivityLabelPolicy | Where-Object { $_.Name -like $AdditionalNamePattern }
}
$labelPolicies = $labelPolicies | Sort-Object Name -Unique

foreach ($p in $labelPolicies) {
    $daysSinceChange = if ($p.WhenChanged) { ($today - $p.WhenChanged).Days } else { $null }
    $inTestMode = $p.Mode -in @("TestWithNotifications", "TestWithoutNotifications", "Test")
    $stale = $inTestMode -and $daysSinceChange -ne $null -and $daysSinceChange -ge $StaleValidationDays

    $results.Add([PSCustomObject]@{
        PolicyType        = "AutoLabeling"
        Name              = $p.Name
        Mode              = $p.Mode
        Enabled           = $p.Enabled
        Workload          = ($p.Workload -join ", ")
        WhenCreated       = $p.WhenCreated
        WhenChanged       = $p.WhenChanged
        DaysSinceChange   = $daysSinceChange
        InTestMode        = $inTestMode
        StaleValidation   = $stale
        Severity          = if ($stale) { "WARN - validation may be stalled" }
                             elseif ($inTestMode) { "INFO - awaiting cutover decision" }
                             else { "OK - enforcing" }
    })
}

# ---- Report ----------------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Status "No matching DLP or auto-labeling policies found for pattern(s) supplied." "WARN"
    Write-Status "This does NOT mean no MDA File policies exist — that inventory is Defender-portal-only and must be checked manually at Cloud apps > Policies > Policy management." "WARN"
}
else {
    Write-Status "Found $($results.Count) matching Purview polic$(if ($results.Count -eq 1) {'y'} else {'ies'})." "OK"
    $results | Sort-Object PolicyType, StaleValidation -Descending | Format-Table -AutoSize

    $staleCount = ($results | Where-Object { $_.StaleValidation }).Count
    if ($staleCount -gt 0) {
        Write-Status "$staleCount polic$(if ($staleCount -eq 1) {'y'} else {'ies'}) flagged as stalled validation (in test mode, unchanged for $StaleValidationDays+ days) — review for cutover or escalate." "WARN"
    }

    $exportPath = Join-Path -Path (Get-Location) -ChildPath "FilePolicyRetirementAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $results | Export-Csv -Path $exportPath -NoTypeInformation
    Write-Status "Exported full results to $exportPath" "OK"
}

Write-Status "Reminder: MDA File policy inventory, migration-wizard verdicts/Notes, and Activity explorer match-history comparisons must still be gathered manually from the Defender and Purview portals — see FilePolicyRetirement-A.md Evidence Pack for the full escalation checklist." "INFO"
