<#
.SYNOPSIS
    Audits Microsoft Purview adaptive scopes for lifecycle-status (active/inactive/soft-deleted)
    evaluation exposure ahead of the MC1450128 rollout.

.DESCRIPTION
    Companion script to Security/Purview/RetentionLabels-A.md, -B.md, CommunicationCompliance-A.md,
    and -B.md.

    Microsoft Purview is introducing lifecycle-status evaluation controls for adaptive scopes
    (Message Center MC1450128, Microsoft 365 Roadmap ID 568785): Public Preview begins
    mid-September 2026 (complete early October 2026), General Availability begins mid-October 2026
    (complete mid-November 2026). Newly created adaptive scopes will evaluate ONLY active
    recipients and site owners by default; existing scopes are NOT automatically modified and keep
    their current (implicit, effectively lifecycle-status-agnostic unless an admin already added an
    explicit IsInactiveMailbox clause) behavior.

    There is no dedicated cmdlet, as of this writing, to read a scope's lifecycle-status evaluation
    setting directly (that state lives in the Purview portal: Settings > Roles and scopes >
    Adaptive scopes > <scope> > Details). This script cannot read that flag. Instead it audits the
    adjacent signals this repo's runbooks depend on:
      - Inventories all adaptive scopes (Get-AdaptiveScope) and their type/creation/last-query time
      - Flags scopes whose advanced query does NOT contain an explicit IsInactiveMailbox clause,
        i.e. scopes whose lifecycle-status behavior is currently implicit and will silently inherit
        whatever the platform default becomes at GA
      - Cross-references each User-type scope's live membership against Get-Recipient to sample
        whether inactive mailboxes are present today (best-effort; large scopes are sampled, not
        fully enumerated, per the platform's own documented reconciliation approach)
      - Flags scopes referenced by retention or communication compliance policies used for
        offboarding/legal-hold scenarios (name-pattern heuristic only — always confirm manually)
      - Emits a plain-language readiness summary and a CSV export for escalation/handoff

    This is a READ-ONLY audit script. It makes no configuration changes and cannot enable, disable,
    or set the new lifecycle-status controls (no cmdlet surface exists for that yet).

.PARAMETER AdminUPN
    UPN to use for Connect-IPPSSession. If omitted, assumes an existing IPPS session is present.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to the current user's temp folder.

.PARAMETER SampleSize
    Maximum number of recipients to sample per scope when checking for inactive-mailbox presence.
    Defaults to 500 to avoid excessive runtime/throttling on large tenants.

.EXAMPLE
    .\Get-AdaptiveScopeLifecycleAudit.ps1 -AdminUPN admin@contoso.com

    Connects, inventories every adaptive scope, flags implicit-lifecycle-status scopes, and
    exports a CSV readiness report.

.EXAMPLE
    .\Get-AdaptiveScopeLifecycleAudit.ps1 -SampleSize 2000 -ExportPath C:\Temp\ScopeAudit.csv

    Runs against an existing IPPS session with a larger sample size and a fixed export path.

.NOTES
    Requires: ExchangeOnlineManagement module (Connect-IPPSSession) with Compliance
    Administrator / Organization Management / Records Management rights (any built-in role group
    that includes the Scope Manager role can create/read adaptive scopes).
    Safe/unsafe: read-only, no writes. Large tenants: membership sampling is capped by -SampleSize
    to control runtime; increase deliberately, not by default.
    Rollout reference: MC1450128 / Roadmap 568785. Preview mid-Sep 2026, GA mid-Oct-mid-Nov 2026.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminUPN,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = (Join-Path $env:TEMP "AdaptiveScopeLifecycleAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"),

    [Parameter(Mandatory = $false)]
    [int]$SampleSize = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# Name-pattern heuristic only — always confirm manually against the actual policies
# that consume each scope before treating a hit/miss here as authoritative.
$offboardingNamePatterns = @("*offboard*", "*departed*", "*legal*hold*", "*termination*", "*exit*", "*leaver*")

# --- Preflight ---
Write-Status "Adaptive Scope Lifecycle-Status Readiness Audit (MC1450128 / Roadmap 568785)" "INFO"
Write-Status "Rollout: Public Preview mid-Sep 2026 (complete early Oct 2026); GA mid-Oct-mid-Nov 2026." "INFO"

try {
    Get-Command Get-AdaptiveScope -ErrorAction Stop | Out-Null
}
catch {
    if ($AdminUPN) {
        Write-Status "No active IPPS session detected — connecting as $AdminUPN" "INFO"
        Connect-IPPSSession -UserPrincipalName $AdminUPN
    }
    else {
        Write-Status "Get-AdaptiveScope not found and no -AdminUPN supplied. Run Connect-IPPSSession first or pass -AdminUPN." "ERROR"
        throw "Not connected to Security & Compliance PowerShell (Connect-IPPSSession)."
    }
}

# --- Detect ---
Write-Status "Enumerating adaptive scopes..." "INFO"
$scopes = @(Get-AdaptiveScope -ErrorAction Stop)

if ($scopes.Count -eq 0) {
    Write-Status "No adaptive scopes found in this tenant. Nothing to audit." "WARN"
    return
}

Write-Status "Found $($scopes.Count) adaptive scope(s)." "OK"

$results = New-Object System.Collections.Generic.List[Object]

foreach ($scope in $scopes) {

    $scopeName      = $scope.Name
    $scopeType      = $scope.ScopeType
    $lastQueryTime  = $scope.LastQueryTime
    $whenCreated    = $scope.WhenCreated
    $rawQuery       = ($scope.RawFilter -join " ") 2>$null
    if (-not $rawQuery) { $rawQuery = ($scope | Select-Object -ExpandProperty RawQuery -ErrorAction SilentlyContinue) }

    $hasExplicitLifecycleClause = $false
    if ($rawQuery -and ($rawQuery -match "IsInactiveMailbox")) {
        $hasExplicitLifecycleClause = $true
    }

    $looksOffboardingRelated = $false
    foreach ($pattern in $offboardingNamePatterns) {
        if ($scopeName -like $pattern) { $looksOffboardingRelated = $true; break }
    }

    $inactiveMembersSampled = $null
    $sampleNote = "Not sampled (non-User scope type)"

    if ($scopeType -eq "User" -or $scopeType -eq "Users") {
        try {
            # Best-effort sample: this does NOT reproduce the scope's exact query membership
            # (that requires re-running the scope's own filter, which this script does not
            # attempt to parse/execute) — it is a tenant-wide inactive-mailbox presence check
            # to give a rough signal, not a per-scope precise count.
            $inactiveSample = @(Get-Mailbox -InactiveMailboxOnly -ResultSize $SampleSize -ErrorAction SilentlyContinue)
            $inactiveMembersSampled = $inactiveSample.Count
            $sampleNote = "Tenant-wide inactive-mailbox count (sampled, capped at $SampleSize) — not scope-filtered"
        }
        catch {
            $sampleNote = "Sampling failed: $($_.Exception.Message)"
        }
    }

    $riskFlag = if (-not $hasExplicitLifecycleClause) {
        "REVIEW — implicit lifecycle behavior, will inherit new platform default at GA"
    } else {
        "OK — explicit IsInactiveMailbox clause already present"
    }

    if ($looksOffboardingRelated -and -not $hasExplicitLifecycleClause) {
        $riskFlag = "HIGH PRIORITY — offboarding-pattern name AND implicit lifecycle behavior"
    }

    $results.Add([PSCustomObject]@{
        ScopeName                  = $scopeName
        ScopeType                  = $scopeType
        WhenCreated                = $whenCreated
        LastQueryTime               = $lastQueryTime
        HasExplicitLifecycleClause = $hasExplicitLifecycleClause
        LooksOffboardingRelated    = $looksOffboardingRelated
        TenantInactiveMailboxSample = $inactiveMembersSampled
        SampleNote                 = $sampleNote
        RiskFlag                   = $riskFlag
    })
}

# --- Validate / Report ---
$reviewCount = ($results | Where-Object { $_.RiskFlag -like "REVIEW*" -or $_.RiskFlag -like "HIGH PRIORITY*" }).Count
$highPriorityCount = ($results | Where-Object { $_.RiskFlag -like "HIGH PRIORITY*" }).Count

Write-Host ""
Write-Status "=== Summary ===" "INFO"
Write-Status "Total adaptive scopes: $($scopes.Count)" "INFO"
Write-Status "Scopes with implicit lifecycle-status behavior: $reviewCount" $(if ($reviewCount -gt 0) { "WARN" } else { "OK" })
Write-Status "High-priority (offboarding-pattern name + implicit behavior): $highPriorityCount" $(if ($highPriorityCount -gt 0) { "WARN" } else { "OK" })
Write-Host ""
Write-Status "IMPORTANT: this script cannot read the actual lifecycle-status evaluation setting once" "WARN"
Write-Status "the native control ships (no cmdlet surface documented as of this writing). Confirm final" "WARN"
Write-Status "state per-scope in: Purview portal > Settings > Roles and scopes > Adaptive scopes >" "WARN"
Write-Status "<scope name> > Details." "WARN"

$results | Sort-Object RiskFlag -Descending | Format-Table -AutoSize ScopeName, ScopeType, HasExplicitLifecycleClause, LooksOffboardingRelated, RiskFlag

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $ExportPath" "OK"
