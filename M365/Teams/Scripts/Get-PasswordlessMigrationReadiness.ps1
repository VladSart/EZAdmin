<#
.SYNOPSIS
    Audits Teams shared-device resource accounts for passwordless-migration readiness.

.DESCRIPTION
    Reads Entra ID state for Teams shared-device resource accounts (Teams Rooms on
    Windows/Android, Teams panels, Teams phones/common area phones) and flags the
    conditions that determine whether the account is eligible for the passwordless
    Entra Resource Accounts migration (GA worldwide, August 2026), plus the residual
    password-cleanup posture for accounts already migrated.

    What this script covers (Entra ID / Graph-visible state):
      - Account enabled/disabled
      - License SKU eligibility (Teams Rooms Basic/Pro vs. Teams Shared Space)
      - Hybrid sync status (determines whether the password can later be fully removed,
        or only scrambled)
      - Password-policy state (DisablePasswordExpiration expected on resource accounts)
      - Recent sign-in failure volume (heuristic flag only, not a definitive diagnosis)

    What this script does NOT cover (no documented Graph/PowerShell surface exists as of
    this writing — confirmed via Microsoft Learn, see Learning Pointers in the companion
    runbooks):
      - Actual migration status (Migrated / Failed / Not started) — this lives only in the
        Teams Rooms Pro Management Portal (PMP), Planning > Resource Accounts > Migration tab
      - Device platform/app version compliance — device-side state, not Graph-visible
      - Join type (Entra-ID-joined vs. hybrid-joined) for Teams Rooms on Windows — check via
        `dsregcmd /status` on the device itself
      - Whether the "Set as Resource" attribute has been applied

    This script identifies likely Teams-shared-device resource accounts using a
    display-name heuristic (matching Teams-Rooms-A.md's established approach in this
    repo) plus an explicit -Identity/-UpnList override for precise targeting. Read-only.

.PARAMETER UpnList
    One or more specific resource account UPNs to audit. If omitted, the script scans all
    licensed users whose display name matches a common room/device naming pattern.

.PARAMETER NamePattern
    Display-name substring used for heuristic discovery when -UpnList is not supplied.
    Default: "Room","Panel","Phone","MTR". Case-insensitive.

.PARAMETER ExportPath
    CSV output path. Defaults to .\PasswordlessMigrationReadiness-<timestamp>.csv in the
    current directory.

.EXAMPLE
    .\Get-PasswordlessMigrationReadiness.ps1 -UpnList "room1@contoso.com","panel3@contoso.com"

.EXAMPLE
    .\Get-PasswordlessMigrationReadiness.ps1 -NamePattern "Room","MTR","Panel","Phone"

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Users.Actions modules.
    Run-as: any account with Entra ID Directory.Read.All / User.Read.All scope — read-only,
    no elevated role required.
    Safe: read-only against Graph. Makes no changes to any account, license, or password.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$UpnList,

    [Parameter(Mandatory = $false)]
    [string[]]$NamePattern = @("Room", "Panel", "Phone", "MTR"),

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = ".\PasswordlessMigrationReadiness-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
Write-Status "Connecting to Microsoft Graph..." "INFO"
Connect-MgGraph -Scopes "User.Read.All", "Organization.Read.All", "AuditLog.Read.All" -NoWelcome

$context = Get-MgContext
if (-not $context) {
    Write-Status "Graph connection failed. Aborting." "ERROR"
    return
}
Write-Status "Connected as $($context.Account) to tenant $($context.TenantId)" "OK"

# Known-ish SKU part number fragments for Teams Rooms / Teams Shared Space licensing.
# Matched via -match against SkuPartNumber since exact SKU strings vary by tenant
# licensing history (legacy vs. current naming). Verify against your own tenant's
# Get-MgSubscribedSku output if a known-good license is not being flagged as expected.
$eligibleSkuPatterns = @(
    "MTR_", "TEAMS_ROOMS", "MEETING_ROOM", "TEAMSSHAREDDEVICE", "COMMONAREACAL", "PHONESYSTEM_VIRTUALUSER"
)

# ---- Detect target accounts ----
if ($UpnList) {
    Write-Status "Auditing $($UpnList.Count) explicitly specified account(s)..." "INFO"
    $accounts = foreach ($upn in $UpnList) {
        try {
            Get-MgUser -UserId $upn -Property Id, DisplayName, UserPrincipalName, AccountEnabled, OnPremisesSyncEnabled, PasswordPolicies, CreatedDateTime, SignInActivity
        } catch {
            Write-Status "Could not resolve $upn : $($_.Exception.Message)" "WARN"
        }
    }
} else {
    Write-Status "No -UpnList supplied. Discovering candidate accounts by display-name pattern: $($NamePattern -join ', ')" "INFO"
    $filterClauses = ($NamePattern | ForEach-Object { "contains(displayName,'$_')" }) -join " or "
    $accounts = Get-MgUser -Filter $filterClauses -Property Id, DisplayName, UserPrincipalName, AccountEnabled, OnPremisesSyncEnabled, PasswordPolicies, CreatedDateTime, SignInActivity -All -ConsistencyLevel eventual -CountVariable discoveredCount
    Write-Status "Discovered $($accounts.Count) candidate account(s) via naming heuristic. Review results — this is a heuristic, not an authoritative device inventory." "INFO"
}

if (-not $accounts -or $accounts.Count -eq 0) {
    Write-Status "No candidate resource accounts found. Exiting." "WARN"
    return
}

# ---- Evaluate each account ----
$results = foreach ($acct in $accounts) {

    $findings = [System.Collections.Generic.List[string]]::new()
    $severity = "OK"

    if (-not $acct.AccountEnabled) {
        $findings.Add("ACCOUNT_DISABLED")
        $severity = "CRITICAL"
    }

    $licenses = @()
    try {
        $licenses = Get-MgUserLicenseDetail -UserId $acct.Id -ErrorAction Stop
    } catch {
        $findings.Add("LICENSE_LOOKUP_FAILED")
    }

    $hasEligibleSku = $false
    foreach ($lic in $licenses) {
        foreach ($pattern in $eligibleSkuPatterns) {
            if ($lic.SkuPartNumber -match $pattern) { $hasEligibleSku = $true }
        }
    }
    if (-not $hasEligibleSku) {
        $findings.Add("NO_ELIGIBLE_LICENSE_DETECTED")
        if ($severity -ne "CRITICAL") { $severity = "WARN" }
    }

    $passwordCleanupPath = if ($acct.OnPremisesSyncEnabled) {
        $findings.Add("HYBRID_SYNCED_PASSWORD_SCRAMBLE_ONLY")
        "Scramble only (hybrid-synced — password cannot be deleted)"
    } else {
        "Cleanup wizard eligible (cloud-only)"
    }

    $passwordNeverExpires = $acct.PasswordPolicies -match "DisablePasswordExpiration"
    if (-not $passwordNeverExpires) {
        $findings.Add("PASSWORD_EXPIRATION_NOT_DISABLED")
        if ($severity -eq "OK") { $severity = "WARN" }
    }

    # Heuristic staleness / failure signal — sign-in activity is a supplementary signal only,
    # not a substitute for checking the PMP Migration tab or Entra sign-in logs directly.
    $lastSignIn = $null
    if ($acct.SignInActivity -and $acct.SignInActivity.LastSignInDateTime) {
        $lastSignIn = $acct.SignInActivity.LastSignInDateTime
        $daysSinceSignIn = (New-TimeSpan -Start $lastSignIn -End (Get-Date)).Days
        if ($daysSinceSignIn -gt 14) {
            $findings.Add("NO_SIGNIN_IN_${daysSinceSignIn}_DAYS")
            if ($severity -eq "OK") { $severity = "WARN" }
        }
    } else {
        $findings.Add("NO_SIGNIN_ACTIVITY_DATA")
    }

    if ($findings.Count -eq 0) { $findings.Add("READY_FOR_PMP_MIGRATION_REVIEW") }

    [PSCustomObject]@{
        DisplayName           = $acct.DisplayName
        UserPrincipalName     = $acct.UserPrincipalName
        AccountEnabled        = $acct.AccountEnabled
        OnPremisesSyncEnabled = $acct.OnPremisesSyncEnabled
        PasswordCleanupPath   = $passwordCleanupPath
        LicenseSkus           = (($licenses | Select-Object -ExpandProperty SkuPartNumber) -join "; ")
        EligibleLicenseFound  = $hasEligibleSku
        LastSignInDateTime    = $lastSignIn
        Severity              = $severity
        Findings              = ($findings -join "; ")
    }
}

# ---- Report ----
Write-Host "`n=== Passwordless Migration Readiness Summary ===" -ForegroundColor Cyan
$results | Sort-Object Severity, DisplayName | Format-Table DisplayName, Severity, EligibleLicenseFound, OnPremisesSyncEnabled, Findings -AutoSize

$critical = ($results | Where-Object { $_.Severity -eq "CRITICAL" }).Count
$warn = ($results | Where-Object { $_.Severity -eq "WARN" }).Count
$ok = ($results | Where-Object { $_.Severity -eq "OK" }).Count

Write-Status "$ok account(s) show no Entra-side blockers detected. $warn flagged WARN. $critical flagged CRITICAL." $(if ($critical -gt 0) { "ERROR" } elseif ($warn -gt 0) { "WARN" } else { "OK" })

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full results exported to $ExportPath" "OK"

Write-Host "`nReminder: this script cannot see PMP migration status, device platform/app version," -ForegroundColor Yellow
Write-Host "or join type (Entra-ID-joined vs. hybrid-joined). Cross-check flagged accounts against" -ForegroundColor Yellow
Write-Host "the PMP Migration tab and, for Teams Rooms on Windows, 'dsregcmd /status' on the device" -ForegroundColor Yellow
Write-Host "before scheduling migration. See PasswordlessResourceAccounts-A.md Validation Steps." -ForegroundColor Yellow
