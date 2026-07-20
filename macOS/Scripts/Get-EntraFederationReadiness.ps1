<#
.SYNOPSIS
    Audits a set of Entra ID users for Managed Apple ID (Apple Business) federation
    readiness, and reports recent password-change/reset events that would explain a
    forced Apple device sign-out.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/ManagedAppleID-Federation-A.md and
    ManagedAppleID-Federation-B.md. This is an admin-side, Entra-only check — there is
    no public Apple Business API to query federation/directory-sync state directly, so
    the Apple Business console checks (federation toggle, Account Conflict banner,
    directory sync last-sync time, and the role assigned to the federation-setup
    account) must still be done manually in business.apple.com. See both runbooks'
    Validation Steps for the exact console paths.

    For each user in scope, this reports:
    - UserPrincipalName vs. Mail match — the single highest-frequency real-world
      federation failure per both runbooks' Triage/Symptom-Cause sections. Flags
      UPN_MISMATCH.
    - Presence of entries in OtherMails that could indicate an Alternate Login ID /
      alias scenario, which is also unsupported for this federation. Flags
      POSSIBLE_ALIAS.
    - Domain verification state for the user's UPN domain via Get-MgDomain. Flags
      DOMAIN_NOT_VERIFIED.
    - Recent ChangePassword/ResetPassword directory-audit events within
      -RecentPasswordEventHours (default 24) — explains an expected forced
      reauthentication on Apple devices per Fix 4 in the B runbook. Flags
      RECENT_PASSWORD_EVENT (informational, not necessarily a problem).

    Read-only. Makes no changes to any user, domain, or federation configuration.

.PARAMETER UserPrincipalName
    One or more UPNs to check. If omitted, prompts for at least one.

.PARAMETER RecentPasswordEventHours
    Window, in hours, to look back for password change/reset audit events.
    Default 24, matching the runbook's forced-reauthentication troubleshooting window.

.PARAMETER OutputPath
    Path to export a CSV report. Default: $env:TEMP\EntraFederationReadiness-<date>.csv

.EXAMPLE
    .\Get-EntraFederationReadiness.ps1 -UserPrincipalName "jane.doe@contoso.com"

.EXAMPLE
    .\Get-EntraFederationReadiness.ps1 -UserPrincipalName "jane.doe@contoso.com","john.smith@contoso.com" -RecentPasswordEventHours 48

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement,
              Microsoft.Graph.Reports modules
    Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Domain.Read.All"
    Run as:   Any account with Entra ID read rights covering the above scopes
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: macOS/Troubleshooting/ManagedAppleID-Federation-A.md,
    ManagedAppleID-Federation-B.md
    Does NOT check Apple Business-side federation toggle, directory sync state, or
    Account Conflict banners — no public API exists for those; check business.apple.com
    directly (see both runbooks' Validation Steps).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$UserPrincipalName,

    [int]$RecentPasswordEventHours = 24,

    [string]$OutputPath = "$env:TEMP\EntraFederationReadiness-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

Write-Status "Entra Federation Readiness check started — $(Get-Date)" "INFO"

# ─── Preflight ──────────────────────────────────────────────────────────────────

try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    $requiredScopes = @("User.Read.All", "AuditLog.Read.All", "Domain.Read.All")
    $missing = $requiredScopes | Where-Object { $ctx.Scopes -notcontains $_ }
    if ($missing) {
        Write-Status "Current Graph session is missing scopes: $($missing -join ', ') — connecting again." "WARN"
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
} catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Domain.Read.All" -NoWelcome
}

# ─── Detect: pull user + domain state ───────────────────────────────────────────

$Results = [System.Collections.Generic.List[PSObject]]::new()
$domainCache = @{}
$cutoff = (Get-Date).ToUniversalTime().AddHours(-$RecentPasswordEventHours)

foreach ($upn in $UserPrincipalName) {

    Write-Host ""
    Write-Status "Checking $upn ..." "INFO"

    try {
        $user = Get-MgUser -UserId $upn -Property "UserPrincipalName,Mail,OtherMails,GivenName,Surname,Department,Id" -ErrorAction Stop
    } catch {
        Write-Status "  Could not find user '$upn': $($_.Exception.Message)" "ERROR"
        $Results.Add([PSCustomObject]@{
            UserPrincipalName      = $upn
            Mail                   = $null
            UPNMatchesMail         = $false
            OtherMailsCount        = $null
            DomainVerified         = $null
            RecentPasswordEvent    = $null
            Flags                  = "USER_NOT_FOUND"
            Status                 = "ERROR"
        })
        continue
    }

    $flags = [System.Collections.Generic.List[string]]::new()

    # UPN vs Mail match — the #1 real-world failure per the runbook
    $upnMatchesMail = ($user.UserPrincipalName -eq $user.Mail)
    if (-not $upnMatchesMail) {
        $flags.Add("UPN_MISMATCH")
    }

    # Alias / Alternate Login ID risk signal
    $otherMailsCount = if ($user.OtherMails) { $user.OtherMails.Count } else { 0 }
    if ($otherMailsCount -gt 0) {
        $flags.Add("POSSIBLE_ALIAS")
    }

    # Domain verification state
    $domainName = $user.UserPrincipalName.Split('@')[1]
    if (-not $domainCache.ContainsKey($domainName)) {
        try {
            $domainCache[$domainName] = Get-MgDomain -DomainId $domainName -ErrorAction Stop
        } catch {
            $domainCache[$domainName] = $null
        }
    }
    $domainObj = $domainCache[$domainName]
    $domainVerified = if ($domainObj) { $domainObj.IsVerified } else { $null }
    if ($domainVerified -eq $false -or $null -eq $domainObj) {
        $flags.Add("DOMAIN_NOT_VERIFIED")
    }

    # Recent password change/reset event
    $recentPasswordEvent = $null
    try {
        $auditEvents = Get-MgAuditLogDirectoryAudit `
            -Filter "activityDisplayName eq 'Reset password' or activityDisplayName eq 'Change password'" `
            -Top 50 -ErrorAction Stop |
            Where-Object { $_.TargetResources.UserPrincipalName -contains $user.UserPrincipalName }

        $recentEvent = $auditEvents | Where-Object { $_.ActivityDateTime -ge $cutoff } | Select-Object -First 1
        if ($recentEvent) {
            $recentPasswordEvent = $recentEvent.ActivityDateTime
            $flags.Add("RECENT_PASSWORD_EVENT")
        }
    } catch {
        Write-Status "  Could not query audit log for $upn`: $($_.Exception.Message)" "WARN"
    }

    $status = if ($flags.Contains("UPN_MISMATCH") -or $flags.Contains("DOMAIN_NOT_VERIFIED")) {
        "ERROR"
    } elseif ($flags.Count -gt 0) {
        "WARN"
    } else {
        "OK"
    }

    Write-Status "  UPN=$($user.UserPrincipalName) Mail=$($user.Mail) Match=$upnMatchesMail DomainVerified=$domainVerified" $status
    if ($flags.Count -gt 0) {
        Write-Status "    Flags: $($flags -join ', ')" $status
    }

    $Results.Add([PSCustomObject]@{
        UserPrincipalName      = $user.UserPrincipalName
        Mail                   = $user.Mail
        UPNMatchesMail         = $upnMatchesMail
        OtherMailsCount        = $otherMailsCount
        Domain                 = $domainName
        DomainVerified         = $domainVerified
        RecentPasswordEvent    = $recentPasswordEvent
        Flags                  = ($flags -join "; ")
        Status                 = $status
    })
}

# ─── Report: summary ────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta

$mismatches   = $Results | Where-Object { $_.Flags -match "UPN_MISMATCH" }
$aliasRisk    = $Results | Where-Object { $_.Flags -match "POSSIBLE_ALIAS" }
$domainIssues = $Results | Where-Object { $_.Flags -match "DOMAIN_NOT_VERIFIED" }
$pwEvents     = $Results | Where-Object { $_.Flags -match "RECENT_PASSWORD_EVENT" }

Write-Status "Users checked:                  $($Results.Count)"
Write-Status "UPN/Mail mismatches:            $($mismatches.Count)"   $(if ($mismatches.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Possible alias/Alternate ID:     $($aliasRisk.Count)"    $(if ($aliasRisk.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Domain verification issues:      $($domainIssues.Count)" $(if ($domainIssues.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Recent password events:          $($pwEvents.Count)"    $(if ($pwEvents.Count -gt 0) { "WARN" } else { "OK" })

if ($mismatches.Count -gt 0) {
    Write-Host ""
    Write-Host "ACTION NEEDED — these users cannot use Managed Apple ID federation until" -ForegroundColor Yellow
    Write-Host "UserPrincipalName is corrected to match Mail. See Federation-B.md Fix 2." -ForegroundColor Yellow
}

if ($pwEvents.Count -gt 0) {
    Write-Host ""
    Write-Host "Users with a recent password event will see (or have seen) a forced" -ForegroundColor Yellow
    Write-Host "reauthentication on every Apple device — this is expected. See Fix 4." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Reminder — this script cannot check the following; verify manually in" -ForegroundColor Cyan
Write-Host "Apple Business (business.apple.com):" -ForegroundColor Cyan
Write-Host "  - Domain federation toggle state (Settings > Domains > [domain])"
Write-Host "  - Account Conflict banner presence"
Write-Host "  - Directory sync connection + last-sync timestamp"
Write-Host "  - Role assigned to the account that configured federation"

# ─── Export ──────────────────────────────────────────────────────────────────────

$Results | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "`nFull report: $OutputPath" "INFO"
Write-Status "Done." "OK"
