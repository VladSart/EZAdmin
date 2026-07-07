<#
.SYNOPSIS
    Tenant-wide audit of App Registration credential expiry and ownership
    gaps — surfaces the two silent failure modes AppRegistrations-A.md and
    AppRegistrations-B.md flag as the most common cause of unannounced
    automation/integration outages.

.DESCRIPTION
    Enumerates every Application object in the tenant and, for each one:
    - Inventories all client secrets (passwordCredentials) and certificates
      (keyCredentials) with their expiry dates
    - Flags EXPIRED credentials (already broken) and EXPIRING credentials
      (within -WarningDays, default 30) separately
    - Checks Application object ownership — flags ZERO_OWNERS (no one
      receives Entra's 30-day/day-of expiry notification emails at all) and
      OWNERS_DISABLED (every owner account is disabled, functionally the
      same outcome) per AppRegistrations-A.md's Learning Pointers
    - Cross-checks the corresponding Service Principal (if one exists in
      this tenant) for AccountEnabled state and its OWN, separate owner
      list, since AppRegistrations-A.md's architecture section notes the
      Application and Service Principal owner lists are not the same thing
    - Flags NO_SERVICE_PRINCIPAL for any Application with no matching SP in
      the current tenant — either never used here, or a multi-tenant app
      whose consent was never completed (see AppRegistrations-B.md Fix 4)
    - Computes an overall RiskLevel per app: CRITICAL (expired credential,
      zero owners), HIGH (expired credential OR expiring+zero owners),
      MEDIUM (expiring credential with owners, or zero owners with no
      near-term expiry), OK (none of the above)

    Read-only. Makes no changes to any credential, owner, or Service
    Principal. Exports a full CSV plus a filtered "action needed" CSV.

    Does NOT cover:
    - Federated credentials (federatedIdentityCredentials) presence/absence
      — informationally useful but not a failure mode by itself; see
      AppRegistrations-A.md Playbook 2 for migration guidance
    - Actual sign-in failure correlation (AADSTS error codes) — this script
      is a proactive/preventive audit, not a live incident diagnostic; see
      AppRegistrations-B.md Triage for that
    - Consent/permission-grant completeness — see AppRegistrations-A.md
      Validation Step 4 for that check, which is app-specific and not
      meaningfully summarizable fleet-wide

.PARAMETER WarningDays
    Number of days ahead of expiry to flag a credential as EXPIRING rather
    than healthy. Default: 30 (matches Entra's own notification cadence).

.PARAMETER IncludeNoCredentialApps
    If specified, includes apps with zero credentials configured at all in
    the output (normally excluded from the "action needed" list since an
    app with no credentials can't have an expiry problem — though it may
    still be worth reviewing for the zero-owner check).

.PARAMETER OutputPath
    Folder where CSV reports are written. Defaults to
    $env:TEMP\AppRegCredAudit-<timestamp>.

.EXAMPLE
    .\Get-AppRegistrationCredentialAudit.ps1

    Full tenant audit using the default 30-day warning window.

.EXAMPLE
    .\Get-AppRegistrationCredentialAudit.ps1 -WarningDays 60 -OutputPath C:\Reports\AppReg

    Wider 60-day lookahead, custom output folder.

.NOTES
    Requires: Microsoft.Graph.Applications, Microsoft.Graph.Authentication
    Scopes needed: Application.Read.All (Directory.Read.All also works)
    Run As: Any account with Global Reader, Application Administrator, or
            Cloud Application Administrator role
    Safe: Fully read-only — no credentials, owners, or Service Principals
          are modified, added, or removed
    Cross-references: EntraID/Troubleshooting/AppRegistrations-B.md (Triage,
                       Fix 1, Fix 2) and AppRegistrations-A.md (Validation
                       Steps 1-2 and 6, Remediation Playbook 4)
#>

[CmdletBinding()]
param(
    [int]$WarningDays = 30,

    [switch]$IncludeNoCredentialApps,

    [string]$OutputPath = "$env:TEMP\AppRegCredAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

# ---- Preflight ----
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Status "Microsoft.Graph.Applications module not found. Install with: Install-Module Microsoft.Graph.Applications" "ERROR"
    return
}

$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Graph. Connecting with Application.Read.All..." "INFO"
    try {
        Connect-MgGraph -Scopes "Application.Read.All" -NoWelcome -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        return
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$now = Get-Date
$warningCutoff = $now.AddDays($WarningDays)

# ---- Detect: enumerate every Application object ----
Write-Status "Enumerating App Registrations..." "INFO"
try {
    $apps = Get-MgApplication -All -Property Id, AppId, DisplayName, SignInAudience, PasswordCredentials, KeyCredentials, FederatedIdentityCredentials -ErrorAction Stop
    Write-Status "Found $($apps.Count) App Registration(s). Auditing credentials and ownership..." "INFO"
}
catch {
    Write-Status "Failed to enumerate Application objects: $($_.Exception.Message)" "ERROR"
    return
}

$results = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($app in $apps) {
    $i++
    if ($i % 50 -eq 0) { Write-Status "Processed $i of $($apps.Count)..." "INFO" }

    $allCreds = @()
    if ($app.PasswordCredentials) { $allCreds += $app.PasswordCredentials | ForEach-Object { [PSCustomObject]@{ Type = "Secret"; KeyId = $_.KeyId; EndDateTime = $_.EndDateTime } } }
    if ($app.KeyCredentials)      { $allCreds += $app.KeyCredentials      | ForEach-Object { [PSCustomObject]@{ Type = "Certificate"; KeyId = $_.KeyId; EndDateTime = $_.EndDateTime } } }

    if ($allCreds.Count -eq 0 -and -not $IncludeNoCredentialApps) {
        continue
    }

    $expired  = $allCreds | Where-Object { $_.EndDateTime -and $_.EndDateTime -lt $now }
    $expiring = $allCreds | Where-Object { $_.EndDateTime -and $_.EndDateTime -ge $now -and $_.EndDateTime -lt $warningCutoff }
    $soonestExpiry = ($allCreds | Where-Object { $_.EndDateTime } | Sort-Object EndDateTime | Select-Object -First 1).EndDateTime

    # Owners on the Application object
    $ownerCount = 0
    $ownersEnabled = 0
    try {
        $owners = Get-MgApplicationOwner -ApplicationId $app.Id -All -ErrorAction Stop
        $ownerCount = $owners.Count
        foreach ($o in $owners) {
            try {
                $ou = Get-MgUser -UserId $o.Id -Property AccountEnabled -ErrorAction Stop
                if ($ou.AccountEnabled) { $ownersEnabled++ }
            } catch { }
        }
    }
    catch {
        Write-Status "Could not read owners for '$($app.DisplayName)': $($_.Exception.Message)" "WARN"
    }

    # Corresponding Service Principal in this tenant
    $spExists = $false
    $spEnabled = $null
    $spOwnerCount = 0
    try {
        $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction Stop
        if ($sp) {
            $spExists = $true
            $spEnabled = $sp.AccountEnabled
            try {
                $spOwnerCount = (Get-MgServicePrincipalOwner -ServicePrincipalId $sp.Id -All -ErrorAction Stop).Count
            } catch { }
        }
    }
    catch { }

    # ---- Flags ----
    $flags = [System.Collections.Generic.List[string]]::new()
    if ($expired.Count -gt 0)              { $flags.Add("CREDENTIAL_EXPIRED") }
    if ($expiring.Count -gt 0)             { $flags.Add("CREDENTIAL_EXPIRING") }
    if ($ownerCount -eq 0)                 { $flags.Add("ZERO_OWNERS") }
    elseif ($ownersEnabled -eq 0)          { $flags.Add("OWNERS_DISABLED") }
    if ($allCreds.Count -gt 0 -and -not $spExists) { $flags.Add("NO_SERVICE_PRINCIPAL") }
    if ($spExists -and $spEnabled -eq $false)      { $flags.Add("SP_DISABLED") }
    if ($spExists -and $spOwnerCount -eq 0)        { $flags.Add("SP_ZERO_OWNERS") }
    if ($app.FederatedIdentityCredentials -and $app.FederatedIdentityCredentials.Count -gt 0) { $flags.Add("HAS_FEDERATED_CRED") }

    # ---- Risk level ----
    $riskLevel = "OK"
    if ($expired.Count -gt 0 -and $ownerCount -eq 0) {
        $riskLevel = "CRITICAL"   # already broken, and nobody was ever going to be warned
    }
    elseif ($expired.Count -gt 0) {
        $riskLevel = "HIGH"       # already broken
    }
    elseif ($expiring.Count -gt 0 -and ($ownerCount -eq 0 -or $ownersEnabled -eq 0)) {
        $riskLevel = "HIGH"       # about to break, and no one will be notified
    }
    elseif ($expiring.Count -gt 0 -or $ownerCount -eq 0) {
        $riskLevel = "MEDIUM"
    }

    $results.Add([PSCustomObject]@{
        DisplayName       = $app.DisplayName
        AppId             = $app.AppId
        SignInAudience    = $app.SignInAudience
        TotalCredentials  = $allCreds.Count
        ExpiredCount      = $expired.Count
        ExpiringCount     = $expiring.Count
        SoonestExpiry     = $soonestExpiry
        AppOwnerCount     = $ownerCount
        AppOwnersEnabled  = $ownersEnabled
        ServicePrincipalExists  = $spExists
        ServicePrincipalEnabled = $spEnabled
        SPOwnerCount      = $spOwnerCount
        HasFederatedCred  = [bool]($app.FederatedIdentityCredentials -and $app.FederatedIdentityCredentials.Count -gt 0)
        RiskLevel         = $riskLevel
        Flags             = ($flags -join ";")
    })
}

# ---- Report ----
Write-Host ""
Write-Host "=== App Registration Credential Audit Summary ===" -ForegroundColor Cyan
Write-Status "$($results.Count) app(s) evaluated (with at least one credential, unless -IncludeNoCredentialApps was used)." "INFO"

$critical = $results | Where-Object { $_.RiskLevel -eq "CRITICAL" }
$high     = $results | Where-Object { $_.RiskLevel -eq "HIGH" }
$medium   = $results | Where-Object { $_.RiskLevel -eq "MEDIUM" }

Write-Status "$($critical.Count) app(s) CRITICAL — expired credential AND zero owners (broken, and no one was ever going to be warned)." $(if ($critical.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "$($high.Count) app(s) HIGH — expired credential, or expiring within $WarningDays day(s) with no reachable owner." $(if ($high.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "$($medium.Count) app(s) MEDIUM — expiring credential (owners in place), or zero owners with no near-term expiry." $(if ($medium.Count -gt 0) { "WARN" } else { "OK" })

$zeroSp = ($results | Where-Object { $_.Flags -match "NO_SERVICE_PRINCIPAL" }).Count
if ($zeroSp -gt 0) {
    Write-Status "$zeroSp app(s) have credentials configured but no Service Principal in this tenant — likely unused here, or a multi-tenant app never consented (see AppRegistrations-B.md Fix 4)." "WARN"
}

Write-Host ""
if ($critical.Count -gt 0) {
    Write-Host "--- CRITICAL: act immediately ---" -ForegroundColor Red
    $critical | Select-Object DisplayName, AppId, ExpiredCount, SoonestExpiry, Flags | Format-Table -AutoSize -Wrap
}
if ($high.Count -gt 0) {
    Write-Host "--- HIGH: act this week ---" -ForegroundColor Yellow
    $high | Select-Object DisplayName, AppId, ExpiredCount, ExpiringCount, SoonestExpiry, Flags | Format-Table -AutoSize -Wrap
}

$exportPath = Join-Path $OutputPath "AppRegistrationCredentialAudit.csv"
$results | Sort-Object @{Expression = { switch ($_.RiskLevel) { "CRITICAL" {0} "HIGH" {1} "MEDIUM" {2} default {3} } }}, SoonestExpiry |
    Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8

$actionPath = Join-Path $OutputPath "ActionNeeded.csv"
$results | Where-Object { $_.RiskLevel -in @("CRITICAL", "HIGH", "MEDIUM") } |
    Export-Csv -Path $actionPath -NoTypeInformation -Encoding UTF8

Write-Status "Full results exported to $exportPath" "OK"
Write-Status "Filtered action-needed list exported to $actionPath" "OK"
