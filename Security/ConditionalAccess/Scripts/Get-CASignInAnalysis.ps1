<#
.SYNOPSIS
    Analyses Entra ID sign-in logs for Conditional Access policy matches, failures,
    and block events — generating a structured CSV report for engineer review.

.DESCRIPTION
    Connects to Microsoft Graph and retrieves sign-in log entries filtered by user,
    date range, and/or CA status. For each entry, reports:
      - Which CA policies matched (and their result: success / failure / notApplied)
      - Error code and failure reason
      - Device compliance state at sign-in time
      - Client app type (modern vs legacy)
      - Location / IP
    Output is exported to CSV and summarised in console.

    Useful for:
      - Diagnosing why a specific user is blocked
      - Auditing which CA policies are blocking sign-ins across the tenant
      - Pre-migration validation (Report-Only policy review)
      - Identifying legacy auth still in use

.PARAMETER UserPrincipalName
    UPN of the user to analyse. If omitted, retrieves tenant-wide sign-ins.

.PARAMETER Days
    Number of days back to retrieve sign-ins. Default: 7.

.PARAMETER MaxResults
    Maximum number of sign-in entries to retrieve. Default: 500.

.PARAMETER FailedOnly
    Switch. If set, only retrieves failed/blocked sign-ins (errorCode ne 0).

.PARAMETER CABlockedOnly
    Switch. If set, only retrieves sign-ins where CA result was 'failure' or 'blocked'.

.PARAMETER OutputPath
    Path for the CSV export. Default: $env:TEMP\CA-SignIn-Analysis-<timestamp>.csv

.EXAMPLE
    # Analyse all sign-ins for a specific user over the last 14 days
    .\Get-CASignInAnalysis.ps1 -UserPrincipalName "alice@contoso.com" -Days 14

.EXAMPLE
    # Tenant-wide blocked sign-ins, last 7 days
    .\Get-CASignInAnalysis.ps1 -CABlockedOnly -Days 7

.EXAMPLE
    # Failed sign-ins only, output to custom path
    .\Get-CASignInAnalysis.ps1 -FailedOnly -OutputPath "C:\Reports\ca-audit.csv"

.NOTES
    Requires: Microsoft.Graph PowerShell SDK (Install-Module Microsoft.Graph)
    Required scopes: AuditLog.Read.All, Directory.Read.All
    Minimum role: Reports Reader or Security Reader
    Safe: Read-only. Makes no changes to the tenant.
    Rate limiting: Graph sign-in logs endpoint is throttled at ~200 req/min.
                   Script uses -Top with a hard limit; large tenants may need date-range scoping.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 30)]
    [int]$Days = 7,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 2000)]
    [int]$MaxResults = 500,

    [Parameter(Mandatory = $false)]
    [switch]$FailedOnly,

    [Parameter(Mandatory = $false)]
    [switch]$CABlockedOnly,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
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

function Test-GraphConnected {
    try {
        $ctx = Get-MgContext
        if (-not $ctx) { return $false }
        $requiredScopes = @("AuditLog.Read.All")
        $missingScopes = $requiredScopes | Where-Object { $_ -notin $ctx.Scopes }
        if ($missingScopes) {
            Write-Status "Connected to Graph but missing scopes: $($missingScopes -join ', ')" "WARN"
            Write-Status "Reconnecting with required scopes..." "INFO"
            return $false
        }
        return $true
    }
    catch { return $false }
}

#region ── PREFLIGHT ──────────────────────────────────────────────────────────
Write-Status "CA Sign-In Analysis — preflight checks" "INFO"

# Ensure Microsoft.Graph module available
if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Reports" -EA SilentlyContinue)) {
    Write-Status "Microsoft.Graph.Reports module not found." "ERROR"
    Write-Status "Install with: Install-Module Microsoft.Graph -Scope CurrentUser" "INFO"
    exit 1
}

Import-Module Microsoft.Graph.Reports -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop

# Connect if not already connected with required scopes
if (-not (Test-GraphConnected)) {
    Write-Status "Connecting to Microsoft Graph..." "INFO"
    Connect-MgGraph -Scopes "AuditLog.Read.All","Directory.Read.All" -NoWelcome
}

$context = Get-MgContext
Write-Status "Connected as: $($context.Account) | TenantId: $($context.TenantId)" "OK"
#endregion

#region ── BUILD FILTER ───────────────────────────────────────────────────────
$cutoff    = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$filters   = @("createdDateTime ge $cutoff")

if ($UserPrincipalName) {
    $filters += "userPrincipalName eq '$UserPrincipalName'"
    Write-Status "Filtering for user: $UserPrincipalName" "INFO"
}

if ($FailedOnly) {
    $filters += "status/errorCode ne 0"
    Write-Status "Filtering: failed sign-ins only" "INFO"
}

$filterString = $filters -join " and "
Write-Status "Filter: $filterString" "INFO"
Write-Status "Retrieving up to $MaxResults sign-in entries from the last $Days days..." "INFO"
#endregion

#region ── RETRIEVE SIGN-INS ─────────────────────────────────────────────────
try {
    $signIns = Get-MgAuditLogSignIn -Filter $filterString -Top $MaxResults -All:$false
}
catch {
    Write-Status "Failed to retrieve sign-in logs: $_" "ERROR"
    exit 1
}

Write-Status "Retrieved $($signIns.Count) sign-in entries." "OK"

if ($signIns.Count -eq 0) {
    Write-Status "No sign-ins found matching the filter. Check the UPN, date range, or permissions." "WARN"
    exit 0
}
#endregion

#region ── PROCESS AND ENRICH ────────────────────────────────────────────────
Write-Status "Processing CA policy evaluation data..." "INFO"

$results = foreach ($signIn in $signIns) {

    # CA Policies evaluation
    $caPolicies = $signIn.ConditionalAccessPolicies
    $caBlocked  = $caPolicies | Where-Object { $_.Result -in @("failure","blocked") }
    $caPassed   = $caPolicies | Where-Object { $_.Result -eq "success" }
    $caNotAppl  = $caPolicies | Where-Object { $_.Result -eq "notApplied" }

    # Skip if CABlockedOnly and no CA failures
    if ($CABlockedOnly -and -not $caBlocked) { continue }

    # Summarise CA policy results as readable string
    $caSummary = if ($caPolicies.Count -eq 0) {
        "No CA policies applied"
    }
    else {
        ($caPolicies | ForEach-Object {
            "$($_.DisplayName) = $($_.Result)"
        }) -join " | "
    }

    $blockedByPolicies = if ($caBlocked) {
        ($caBlocked | ForEach-Object { $_.DisplayName }) -join "; "
    } else { "" }

    [PSCustomObject]@{
        Timestamp           = $signIn.CreatedDateTime
        UPN                 = $signIn.UserPrincipalName
        DisplayName         = $signIn.UserDisplayName
        AppDisplayName      = $signIn.AppDisplayName
        AppId               = $signIn.AppId
        ClientApp           = $signIn.ClientAppUsed        # "Browser","Mobile Apps and Desktop Clients","Exchange ActiveSync","Other clients"
        DeviceId            = $signIn.DeviceDetail.DeviceId
        DeviceName          = $signIn.DeviceDetail.DisplayName
        DeviceOS            = $signIn.DeviceDetail.OperatingSystem
        DeviceCompliant     = $signIn.DeviceDetail.IsCompliant
        DeviceTrustType     = $signIn.DeviceDetail.TrustType
        IsInteractive       = $signIn.IsInteractive
        AuthMethod          = ($signIn.AuthenticationDetails | ForEach-Object { $_.AuthenticationMethod }) -join ", "
        MFADetail           = $signIn.MfaDetail.AuthMethod
        IPAddress           = $signIn.IpAddress
        City                = $signIn.Location.City
        Country             = $signIn.Location.CountryOrRegion
        ErrorCode           = $signIn.Status.ErrorCode
        FailureReason       = $signIn.Status.FailureReason
        CAStatus            = $signIn.ConditionalAccessStatus   # "success","failure","notApplied","unknownFutureValue"
        CA_PolicyCount      = $caPolicies.Count
        CA_BlockedCount     = $caBlocked.Count
        CA_PassedCount      = $caPassed.Count
        CA_NotAppliedCount  = $caNotAppl.Count
        CA_BlockedPolicies  = $blockedByPolicies
        CA_AllPolicies      = $caSummary
        CorrelationId       = $signIn.CorrelationId
        ResourceId          = $signIn.ResourceServicePrincipalId
    }
}

Write-Status "Processed $($results.Count) entries after CA-blocked filter." "OK"
#endregion

#region ── CONSOLE SUMMARY ────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════ SUMMARY ══════════════════════════" -ForegroundColor Cyan

$totalEntries     = $results.Count
$caSuccessCount   = ($results | Where-Object { $_.CAStatus -eq "success" }).Count
$caFailedCount    = ($results | Where-Object { $_.CAStatus -in @("failure","blocked") }).Count
$caNotApplCount   = ($results | Where-Object { $_.CAStatus -eq "notApplied" }).Count
$legacyAuthCount  = ($results | Where-Object { $_.ClientApp -in @("Exchange ActiveSync Clients","Other Clients","SMTP") }).Count

Write-Status "Total sign-in entries: $totalEntries" "INFO"
Write-Status "CA: Success=$caSuccessCount  Blocked/Failed=$caFailedCount  Not applied=$caNotApplCount" "INFO"
Write-Status "Legacy auth sign-ins (potential block targets): $legacyAuthCount" $(if ($legacyAuthCount -gt 0) { "WARN" } else { "OK" })

if ($caFailedCount -gt 0) {
    Write-Host ""
    Write-Status "Top blocking CA policies:" "WARN"
    $results | Where-Object { $_.CA_BlockedPolicies } |
        Group-Object CA_BlockedPolicies |
        Sort-Object Count -Descending |
        Select-Object -First 10 |
        ForEach-Object { Write-Host "  [$($_.Count)x] $($_.Name)" -ForegroundColor Yellow }
}

if ($legacyAuthCount -gt 0) {
    Write-Host ""
    Write-Status "Legacy auth clients in use:" "WARN"
    $results | Where-Object { $_.ClientApp -in @("Exchange ActiveSync Clients","Other Clients","SMTP") } |
        Group-Object ClientApp |
        Sort-Object Count -Descending |
        ForEach-Object { Write-Host "  [$($_.Count)x] $($_.Name)" -ForegroundColor Yellow }
}

Write-Host "═════════════════════════════════════════════════════════════" -ForegroundColor Cyan
#endregion

#region ── EXPORT ─────────────────────────────────────────────────────────────
if (-not $OutputPath) {
    $timestamp  = Get-Date -Format "yyyyMMdd-HHmm"
    $safeName   = if ($UserPrincipalName) { "_" + ($UserPrincipalName -replace '[^a-zA-Z0-9]','_') } else { "_TenantWide" }
    $OutputPath = Join-Path $env:TEMP "CA-SignIn-Analysis$safeName-$timestamp.csv"
}

try {
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "Report exported to: $OutputPath" "OK"
}
catch {
    Write-Status "Failed to export CSV: $_" "ERROR"
}
#endregion

Write-Status "Analysis complete." "OK"
return $results
