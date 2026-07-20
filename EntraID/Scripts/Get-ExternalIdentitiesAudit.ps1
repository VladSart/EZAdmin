<#
.SYNOPSIS
    Audits Entra ID B2B guest users tenant-wide — invitation state, account status, staleness,
    and Cross-Tenant Access Settings (CTAS) coverage — to surface guest hygiene issues before
    they become access-review or security findings.

.DESCRIPTION
    Guest access problems tend to hide until someone escalates a "can't sign in" ticket. This
    script proactively reports on the whole guest population:
      - Guests stuck in PendingAcceptance beyond a configurable threshold (invitation likely
        never delivered or redeemed)
      - Guests disabled (AccountEnabled = false), often left over from an Access Review cycle
      - Guests inactive beyond a configurable threshold (candidates for the stale-guest cleanup
        playbook in ExternalIdentities-A.md)
      - Every configured Cross-Tenant Access Settings (CTAS) partner-tenant rule, so drift from
        the CTAS defaults is visible tenant-wide rather than discovered one partner at a time

    This script is READ-ONLY by design — it reports candidates for action, it does not disable,
    delete, or resend invitations to anyone. Use the Remediation Playbooks in
    EntraID/Troubleshooting/ExternalIdentities-A.md to act on the output.

.PARAMETER StaleDays
    Number of days of inactivity (no sign-in) before a guest is flagged as stale. Default 90.

.PARAMETER PendingDays
    Number of days a guest can remain in PendingAcceptance before being flagged. Default 14.

.PARAMETER OutputPath
    Folder to write CSV reports to. Defaults to C:\Temp\ExternalIdentities-Audit.

.EXAMPLE
    .\Get-ExternalIdentitiesAudit.ps1

.EXAMPLE
    .\Get-ExternalIdentitiesAudit.ps1 -StaleDays 60 -PendingDays 7 -OutputPath "D:\Reports\Guests"

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns modules.
    Requires scopes: User.Read.All, AuditLog.Read.All, Policy.Read.All, Directory.Read.All
    Run: Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Policy.Read.All","Directory.Read.All"
         before running this script.
    Safe/Read-only: makes no changes. Pairs with EntraID/Troubleshooting/ExternalIdentities-A.md
    Playbook 3 (bulk stale-guest cleanup, which itself defaults to -WhatIf).
#>

[CmdletBinding()]
param(
    [int]$StaleDays = 90,
    [int]$PendingDays = 14,
    [string]$OutputPath = "C:\Temp\ExternalIdentities-Audit"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---
foreach ($mod in "Microsoft.Graph.Users", "Microsoft.Graph.Identity.SignIns") {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install-Module $mod -Scope CurrentUser" "ERROR"
        exit 1
    }
}

$context = Get-MgContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Status "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'User.Read.All','AuditLog.Read.All','Policy.Read.All','Directory.Read.All'" "ERROR"
    exit 1
}
Write-Status "Connected to tenant: $($context.TenantId)" "OK"

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$staleCutoff = (Get-Date).AddDays(-$StaleDays)
$pendingCutoff = (Get-Date).AddDays(-$PendingDays)

# --- Pull all guest users ---
Write-Status "Retrieving all guest users (this may take a moment on large tenants)..."
$guests = Get-MgUser -All -Filter "userType eq 'Guest'" `
    -Property Id, DisplayName, Mail, UserPrincipalName, ExternalUserState, ExternalUserStateChangeDateTime, `
              AccountEnabled, CreatedDateTime, SignInActivity

Write-Status "Retrieved $($guests.Count) guest user(s)." "OK"

$report = $guests | ForEach-Object {
    $lastSignIn = $_.SignInActivity.LastSignInDateTime
    $daysSinceSignIn = if ($lastSignIn) { (New-TimeSpan -Start $lastSignIn -End (Get-Date)).Days } else { $null }

    $flags = [System.Collections.Generic.List[string]]::new()
    if ($_.ExternalUserState -eq "PendingAcceptance" -and $_.ExternalUserStateChangeDateTime -lt $pendingCutoff) {
        $flags.Add("StuckPending")
    }
    if (-not $_.AccountEnabled) {
        $flags.Add("Disabled")
    }
    if ((-not $lastSignIn) -or ($lastSignIn -lt $staleCutoff)) {
        $flags.Add("Stale")
    }

    [PSCustomObject]@{
        DisplayName        = $_.DisplayName
        Mail               = $_.Mail
        UserPrincipalName  = $_.UserPrincipalName
        ExternalUserState  = $_.ExternalUserState
        StateChangedOn     = $_.ExternalUserStateChangeDateTime
        AccountEnabled     = $_.AccountEnabled
        CreatedDateTime    = $_.CreatedDateTime
        LastSignIn         = $lastSignIn
        DaysSinceSignIn    = $daysSinceSignIn
        Flags              = ($flags -join ", ")
    }
}

$report | Export-Csv (Join-Path $OutputPath "guest-inventory-$ts.csv") -NoTypeInformation

$stuckPending = $report | Where-Object { $_.Flags -like "*StuckPending*" }
$disabled     = $report | Where-Object { $_.Flags -like "*Disabled*" }
$stale        = $report | Where-Object { $_.Flags -like "*Stale*" }

# --- CTAS partner policy audit ---
Write-Status "Retrieving Cross-Tenant Access Settings (CTAS) partner policies..."
try {
    $ctasPartners = Get-MgPolicyCrossTenantAccessPolicyPartner -All -ErrorAction Stop
    $ctasReport = $ctasPartners | ForEach-Object {
        [PSCustomObject]@{
            TenantId                 = $_.TenantId
            InboundUsersGroups       = $_.B2BCollaborationInbound.UsersAndGroups.AccessType
            OutboundUsersGroups      = $_.B2BCollaborationOutbound.UsersAndGroups.AccessType
            TrustMfa                 = $_.InboundTrust.IsMfaAccepted
            TrustCompliantDevice     = $_.InboundTrust.IsCompliantDeviceAccepted
            TrustHybridJoin          = $_.InboundTrust.IsHybridAzureADJoinedDeviceAccepted
        }
    }
    $ctasReport | Export-Csv (Join-Path $OutputPath "ctas-partners-$ts.csv") -NoTypeInformation
    Write-Status "$($ctasPartners.Count) CTAS partner-tenant rule(s) found." "OK"
} catch {
    Write-Status "Could not retrieve CTAS partner policies: $($_.Exception.Message)" "WARN"
    $ctasPartners = @()
}

# --- External collaboration / invite policy ---
try {
    $authPolicy = Get-MgPolicyAuthorizationPolicy -ErrorAction Stop
    Write-Status "Invite policy (AllowInvitesFrom): $($authPolicy.AllowInvitesFrom)" "INFO"
} catch {
    Write-Status "Could not retrieve authorization policy: $($_.Exception.Message)" "WARN"
}

# --- Summary ---
Write-Host ""
Write-Status "=== EXTERNAL IDENTITIES AUDIT SUMMARY ===" "INFO"
Write-Status "Total guest users               : $($guests.Count)" "INFO"
Write-Status "Stuck in PendingAcceptance (>$PendingDays d) : $($stuckPending.Count)" $(if ($stuckPending.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Disabled (AccountEnabled=false)  : $($disabled.Count)" $(if ($disabled.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Stale / inactive (>$StaleDays d)  : $($stale.Count)" $(if ($stale.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "CTAS partner rules configured    : $(@($ctasPartners).Count)" "INFO"
Write-Status "Full inventory exported to       : $(Join-Path $OutputPath "guest-inventory-$ts.csv")" "OK"

if ($stuckPending.Count -gt 0) {
    Write-Host ""
    Write-Status "Guests stuck in PendingAcceptance (candidates for Playbook 1 - resend invite):" "WARN"
    $stuckPending | Select-Object DisplayName, Mail, StateChangedOn | Format-Table -AutoSize
}
