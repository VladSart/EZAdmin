<#
.SYNOPSIS
    Correlates sign-in log interruptions with directory audit events to identify
    likely Continuous Access Evaluation (CAE) triggered session revocations.

.DESCRIPTION
    Continuous Access Evaluation has no dedicated "CAE event" object exposed via
    Graph — it shows up indirectly as an interrupted/failed sign-in shortly after
    a critical directory event (password reset, account disable, MFA change,
    group removal) or a risk detection. This script automates the manual
    correlation steps in CAE-B.md Triage and Diagnosis & Validation Flow:

    1. Pulls sign-in log entries with Status = Interrupted/Failure in the lookback
       window, for modern/CAE-capable clients.
    2. For each one, checks directory audit logs for a correlating event on the
       same user within +/- CorrelationWindowMinutes.
    3. Classifies each sign-in interruption as:
       - EXPECTED_REVOCATION: correlates with a password reset, account
         disable/enable, or MFA re-registration — CAE working as designed
         (CAE-B.md Fix 1).
       - POSSIBLE_LOCATION_ENFORCEMENT: no directory audit correlation found,
         but multiple interruptions for the same user in a short window suggest
         network/location changes — investigate strict location enforcement
         (CAE-B.md Fix 2).
       - UNCORRELATED: no directory event and no repeating pattern — may not be
         a CAE issue at all; re-check PRT-Issues-B.md or standard token expiry.
    4. Flags MULTI_USER_SPIKE when many distinct users are interrupted in the
       same short window with no individual correlating event — the signature
       of a broad Conditional Access policy change or an Identity Protection
       mass risk event (CAE-B.md Fix 3), not per-user CAE.

    This is a triage aid, not a definitive CAE diagnosis — Graph does not expose
    whether a specific interruption was CAE-driven versus a normal token expiry
    or an unrelated Conditional Access block. Use the classification to decide
    which manual portal steps in CAE-B.md are worth running next. Read-only —
    makes no changes to sign-ins, policies, or users.

    Does NOT cover:
    - Direct confirmation of "strict location enforcement" state on a specific
      Conditional Access policy — Graph does not expose CAE session control
      sub-settings; must be checked in the portal per CAE-B.md Diagnosis Step 3
    - App/client CAE-compatibility classification — see CAE-B.md Fix 4, which
      requires reading the "Client app" field per sign-in and comparing against
      known legacy/basic-auth clients

.PARAMETER LookbackHours
    How many hours of sign-in log history to scan. Default: 24.

.PARAMETER CorrelationWindowMinutes
    Minutes before an interrupted sign-in to look for a correlating directory
    audit event. Default: 15 (matches CAE-B.md Diagnosis Step 2).

.PARAMETER MultiUserSpikeThreshold
    Minimum number of distinct uncorrelated users interrupted within the same
    hour before flagging a MULTI_USER_SPIKE. Default: 5.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\CAE-Session-Events-<timestamp>.csv

.EXAMPLE
    .\Get-CAESessionEvents.ps1

    Scans the last 24 hours of sign-in interruptions and classifies each one.

.EXAMPLE
    .\Get-CAESessionEvents.ps1 -LookbackHours 4 -MultiUserSpikeThreshold 3

    Tighter window for investigating an active, in-progress incident where
    multiple users are reporting sign-outs right now.

.NOTES
    Requires: Microsoft.Graph.Reports, Microsoft.Graph.Identity.SignIns
              PowerShell SDK modules
    Scopes needed: AuditLog.Read.All, Directory.Read.All
    Run As: An account with Security Reader, Reports Reader, or Global Reader role
    Safe: Read-only — no sign-ins, policies, or users are changed
    Cross-references: EntraID/Troubleshooting/CAE-B.md (Triage, Diagnosis &
                       Validation Flow, Fix 1-4)

    Known limitation: Entra sign-in/audit logs default to a 30-day retention
    window (7 days on some license tiers) — LookbackHours beyond that will
    silently return incomplete results. For P1 licensing without extended log
    retention, keep lookback well inside the retention window.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$LookbackHours = 24,

    [ValidateRange(1, 120)]
    [int]$CorrelationWindowMinutes = 15,

    [ValidateRange(2, 100)]
    [int]$MultiUserSpikeThreshold = 5,

    [string]$OutputPath = ".\CAE-Session-Events-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

$correlatingAuditActivities = @(
    "Reset password",
    "Change password",
    "Disable account",
    "Enable account",
    "Delete user",
    "Update user",
    "Add MFA method",
    "Delete MFA method",
    "Remove member from group",
    "Revoke sign-in sessions"
)

# ---- Preflight ----
Write-Status "Checking Microsoft.Graph.Reports module..." "INFO"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Reports)) {
    Write-Status "Microsoft.Graph.Reports module not found. Install with: Install-Module Microsoft.Graph.Reports -Scope CurrentUser" "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Graph. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "AuditLog.Read.All", "Directory.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) [tenant: $($context.TenantId)]" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

$startTime = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
$startTimeStr = $startTime.ToString("yyyy-MM-ddTHH:mm:ssZ")

# ---- Detect: interrupted/failed sign-ins in the window ----
Write-Status "Retrieving sign-in log entries since $startTimeStr (interrupted/failure only)..." "INFO"
$signIns = @()
try {
    $filter = "createdDateTime ge $startTimeStr and (status/errorCode ne 0)"
    $signIns = Get-MgAuditLogSignIn -Filter $filter -All -ErrorAction Stop |
        Where-Object { $_.Status.AdditionalDetails -match "interrupted" -or $_.Status.ErrorCode -in 50097, 50074, 53003, 50158 }
    Write-Status "Found $($signIns.Count) candidate interrupted/failed sign-in(s)." "OK"
}
catch {
    Write-Status "Failed to retrieve sign-in logs: $($_.Exception.Message)" "ERROR"
    return
}

if ($signIns.Count -eq 0) {
    Write-Status "No interrupted sign-ins found in the lookback window. Nothing to correlate." "OK"
    [PSCustomObject]@{ FlagType = "NONE"; Detail = "No interrupted sign-ins in window" } | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    return
}

# ---- Detect: correlate against directory audit logs ----
Write-Status "Retrieving directory audit logs for correlation..." "INFO"
$auditEvents = @()
try {
    $auditEvents = Get-MgAuditLogDirectoryAudit -Filter "activityDateTime ge $startTimeStr" -All -ErrorAction Stop
    Write-Status "Retrieved $($auditEvents.Count) directory audit event(s) for the window." "OK"
}
catch {
    Write-Status "Failed to retrieve directory audit logs: $($_.Exception.Message)" "WARN"
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($si in $signIns) {
    $siTime = $si.CreatedDateTime
    $windowStart = $siTime.AddMinutes(-$CorrelationWindowMinutes)

    $correlated = $auditEvents | Where-Object {
        $_.TargetResources.UserPrincipalName -contains $si.UserPrincipalName -and
        $_.ActivityDateTime -ge $windowStart -and $_.ActivityDateTime -le $siTime -and
        ($correlatingAuditActivities -contains $_.ActivityDisplayName)
    } | Select-Object -First 1

    $classification = if ($correlated) {
        "EXPECTED_REVOCATION"
    }
    else {
        "UNCORRELATED"
    }

    $results.Add([PSCustomObject]@{
        UserPrincipalName    = $si.UserPrincipalName
        SignInTime           = $siTime
        ClientApp            = $si.ClientAppUsed
        AppDisplayName       = $si.AppDisplayName
        ErrorCode            = $si.Status.ErrorCode
        StatusDetail         = $si.Status.AdditionalDetails
        Classification       = $classification
        CorrelatedActivity   = if ($correlated) { $correlated.ActivityDisplayName } else { "-" }
        CorrelatedEventTime  = if ($correlated) { $correlated.ActivityDateTime } else { $null }
    })
}

# ---- Detect: multi-user spike (broad CA/risk event, not per-user CAE) ----
$uncorrelated = $results | Where-Object { $_.Classification -eq "UNCORRELATED" }
$byHour = $uncorrelated | Group-Object { $_.SignInTime.ToString("yyyy-MM-dd HH:00") }
foreach ($hourGroup in $byHour) {
    $distinctUsers = ($hourGroup.Group | Select-Object -ExpandProperty UserPrincipalName -Unique)
    if ($distinctUsers.Count -ge $MultiUserSpikeThreshold) {
        foreach ($r in $hourGroup.Group) {
            $r.Classification = "MULTI_USER_SPIKE"
        }
        Write-Status "Hour $($hourGroup.Name): $($distinctUsers.Count) distinct users interrupted with no individual correlation — likely a broad policy/risk event, not per-user CAE." "ERROR"
    }
    elseif (($hourGroup.Group | Group-Object UserPrincipalName | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
        foreach ($r in $hourGroup.Group) {
            if ($r.Classification -eq "UNCORRELATED") { $r.Classification = "POSSIBLE_LOCATION_ENFORCEMENT" }
        }
    }
}

# ---- Report ----
Write-Host ""
Write-Host "=== CAE Session Event Correlation Summary (last $LookbackHours hrs) ===" -ForegroundColor Cyan
$grouped = $results | Group-Object Classification | Sort-Object Count -Descending
foreach ($g in $grouped) {
    $status = switch ($g.Name) {
        "EXPECTED_REVOCATION"           { "OK" }
        "POSSIBLE_LOCATION_ENFORCEMENT" { "WARN" }
        "MULTI_USER_SPIKE"              { "ERROR" }
        default                         { "WARN" }
    }
    Write-Status "$($g.Name): $($g.Count) event(s)" $status
}
Write-Host ""
$results | Sort-Object Classification, SignInTime | Format-Table UserPrincipalName, SignInTime, ClientApp, Classification, CorrelatedActivity -AutoSize

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to $OutputPath" "OK"
Write-Status "Next step for MULTI_USER_SPIKE or POSSIBLE_LOCATION_ENFORCEMENT results: see CAE-B.md Fix 2/Fix 3 for portal-side confirmation (strict location enforcement config, CA policy change history)." "INFO"
