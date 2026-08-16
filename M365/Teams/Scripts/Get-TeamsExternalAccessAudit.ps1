<#
.SYNOPSIS
    Audits Teams external access (federation), guest access, and cross-tenant B2B direct connect
    (shared channels) posture tenant-wide, and flags precedence conflicts and mutual-config gaps.

.DESCRIPTION
    Automates the Validation Steps and Phase 1/5 troubleshooting flows from ExternalAccess-A.md so
    an admin can see the full external-collaboration exposure surface in one pass instead of
    manually cross-referencing three separate configuration systems (Teams federation, Entra B2B
    invite policy, and Entra cross-tenant access policy).

    Covers:
    - Tenant-wide federation configuration (AllowFederatedUsers, Teams Consumer, allow/block domain
      lists) with a WIDE_OPEN_FEDERATION flag if federation is on with no domain restrictions
    - Entra ID guest invitation authorization policy (AllowInvitesFrom)
    - Cross-tenant access default policy — B2B collaboration and B2B direct connect, inbound and
      outbound, plus inbound trust (MFA / compliant device) settings
    - Every partner-specific cross-tenant access override, with an INCOMPLETE_OVERRIDE flag when a
      partner entry sets some but not all of the four B2B dimensions (collaboration in/out, direct
      connect in/out) — the runbook's Learning Pointers call out that unset dimensions do not
      inherit from the default policy the way an admin might expect
    - Guest account inventory: redemption state (flags STALE_PENDING_INVITE for invites older than
      14 days still showing PendingAcceptance) and last sign-in staleness (flags DORMANT_GUEST for
      accounts with no sign-in in 90+ days, a common access-review finding)
    - Optional per-partner-tenant mutuality check: given a list of partner tenant IDs, reports
      whether B2B direct connect looks configured on your side, since the reciprocal side on the
      partner's tenant cannot be queried from here (flagged explicitly as NEEDS_PARTNER_CONFIRMATION)

    Does NOT cover:
    - The partner tenant's own configuration (not queryable cross-tenant — this script can only
      confirm YOUR side; the runbook's Phase 4 explicitly requires contacting the partner admin)
    - Per-user CsExternalAccessPolicy assignments (preview feature, not yet GA in most tenants;
      script checks tenant-wide CsTenantFederationConfiguration only)
    - SharePoint site-level sharing capability for guest file access (separate script —
      Get-SharePointPermissionAudit.ps1 in the SharePoint-OneDrive folder)

.PARAMETER PartnerTenantIds
    Optional array of partner Entra tenant IDs to check for cross-tenant access overrides and
    B2B direct connect mutuality readiness on your side.

.PARAMETER StaleInviteDays
    Number of days after which a PendingAcceptance guest invite is flagged as stale. Default: 14.

.PARAMETER DormantGuestDays
    Number of days of no sign-in after which a guest account is flagged as dormant. Default: 90.

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-TeamsExternalAccessAudit.ps1 -OutputPath C:\Temp\ExternalAccessAudit

.EXAMPLE
    .\Get-TeamsExternalAccessAudit.ps1 -PartnerTenantIds "11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"

.NOTES
    Requires:
    - MicrosoftTeams module (Connect-MicrosoftTeams)
    - Microsoft.Graph.Identity.SignIns and Microsoft.Graph.Users modules
    - Teams Administrator + Global Reader (minimum) roles; Security Administrator needed to read
      cross-tenant access policy in some tenants

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to policies, guest accounts, or cross-tenant settings.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$PartnerTenantIds = @(),

    [Parameter()]
    [int]$StaleInviteDays = 14,

    [Parameter()]
    [int]$DormantGuestDays = 90,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
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

function Get-FederationAudit {
    Write-Status "Retrieving tenant federation configuration..." "INFO"

    $fedConfig = Get-CsTenantFederationConfiguration

    $flag = "OK"
    if ($fedConfig.AllowFederatedUsers -and
        (-not $fedConfig.BlockedDomains -or $fedConfig.BlockedDomains.Count -eq 0) -and
        (-not $fedConfig.AllowedDomains -or $fedConfig.AllowedDomains.AllowedDomain.Count -eq 0)) {
        $flag = "WIDE_OPEN_FEDERATION"
    }
    elseif (-not $fedConfig.AllowFederatedUsers) {
        $flag = "FEDERATION_DISABLED"
    }

    [PSCustomObject]@{
        AllowFederatedUsers      = $fedConfig.AllowFederatedUsers
        AllowTeamsConsumer       = $fedConfig.AllowTeamsConsumer
        AllowTeamsConsumerInbound = $fedConfig.AllowTeamsConsumerInbound
        BlockedDomainCount       = if ($fedConfig.BlockedDomains) { $fedConfig.BlockedDomains.Count } else { 0 }
        AllowedDomainListInUse   = [bool]($fedConfig.AllowedDomains -and $fedConfig.AllowedDomains.AllowedDomain.Count -gt 0)
        Flag                     = $flag
    }
}

function Get-GuestInviteAudit {
    Write-Status "Retrieving Entra guest invitation authorization policy..." "INFO"

    $authPolicy = Get-MgPolicyAuthorizationPolicy
    $allowInvitesFrom = $authPolicy.AllowInvitesFrom

    $flag = switch ($allowInvitesFrom) {
        "none" { "GUEST_INVITES_FULLY_BLOCKED" }
        "adminsAndGuestInviters" { "INVITES_RESTRICTED_TO_ADMINS" }
        default { "OK" }
    }

    [PSCustomObject]@{
        AllowInvitesFrom = $allowInvitesFrom
        Flag             = $flag
    }
}

function Get-CrossTenantDefaultAudit {
    Write-Status "Retrieving cross-tenant access default policy..." "INFO"

    $default = Get-MgPolicyCrossTenantAccessPolicyDefault

    [PSCustomObject]@{
        B2BCollabInbound      = $default.B2bCollaborationInbound.UsersAndGroups.AccessType
        B2BCollabOutbound     = $default.B2bCollaborationOutbound.UsersAndGroups.AccessType
        B2BDirectConnectIn    = $default.B2bDirectConnectInbound.UsersAndGroups.AccessType
        B2BDirectConnectOut   = $default.B2bDirectConnectOutbound.UsersAndGroups.AccessType
        InboundTrustMFA       = $default.InboundTrust.IsMfaAccepted
        InboundTrustDevice    = $default.InboundTrust.IsCompliantDeviceAccepted
    }
}

function Get-CrossTenantPartnerAudit {
    Write-Status "Retrieving all cross-tenant access partner overrides..." "INFO"

    $partners = Get-MgPolicyCrossTenantAccessPolicyPartner -All

    $results = foreach ($p in $partners) {
        $collabIn   = $p.B2bCollaborationInbound.UsersAndGroups.AccessType
        $collabOut  = $p.B2bCollaborationOutbound.UsersAndGroups.AccessType
        $directIn   = $p.B2bDirectConnectInbound.UsersAndGroups.AccessType
        $directOut  = $p.B2bDirectConnectOutbound.UsersAndGroups.AccessType

        $setDimensions = @($collabIn, $collabOut, $directIn, $directOut) | Where-Object { $_ }
        $flag = "OK"
        if ($setDimensions.Count -gt 0 -and $setDimensions.Count -lt 4) {
            $flag = "INCOMPLETE_OVERRIDE"
        }

        [PSCustomObject]@{
            TenantId            = $p.TenantId
            B2BCollabInbound    = $collabIn
            B2BCollabOutbound   = $collabOut
            B2BDirectConnectIn  = $directIn
            B2BDirectConnectOut = $directOut
            InboundTrustMFA     = $p.InboundTrust.IsMfaAccepted
            Flag                = $flag
        }
    }

    return $results
}

function Get-GuestAccountAudit {
    param([int]$StaleDays, [int]$DormantDays)

    Write-Status "Retrieving guest account inventory (this may take a moment for large tenants)..." "INFO"

    $guests = Get-MgUser -Filter "userType eq 'Guest'" -All `
        -Property Id,DisplayName,Mail,ExternalUserState,ExternalUserStateChangeDateTime,CreatedDateTime,SignInActivity

    $now = Get-Date
    $results = foreach ($g in $guests) {
        $lastSignIn = $g.SignInActivity.LastSignInDateTime
        $daysSinceSignIn = if ($lastSignIn) { ($now - $lastSignIn).Days } else { $null }
        $daysSinceStateChange = if ($g.ExternalUserStateChangeDateTime) { ($now - $g.ExternalUserStateChangeDateTime).Days } else { $null }

        $flags = @()
        if ($g.ExternalUserState -eq "PendingAcceptance" -and $daysSinceStateChange -ge $StaleDays) {
            $flags += "STALE_PENDING_INVITE"
        }
        if ($g.ExternalUserState -eq "Accepted" -and ($null -eq $lastSignIn -or $daysSinceSignIn -ge $DormantDays)) {
            $flags += "DORMANT_GUEST"
        }

        [PSCustomObject]@{
            DisplayName          = $g.DisplayName
            Mail                 = $g.Mail
            ExternalUserState    = $g.ExternalUserState
            DaysSinceStateChange = $daysSinceStateChange
            LastSignIn           = $lastSignIn
            DaysSinceSignIn      = $daysSinceSignIn
            CreatedDateTime      = $g.CreatedDateTime
            Flag                 = if ($flags.Count -gt 0) { $flags -join ";" } else { "OK" }
        }
    }

    return $results
}

function Get-PartnerMutualityCheck {
    param([string[]]$TenantIds)

    if ($TenantIds.Count -eq 0) { return @() }

    Write-Status "Checking B2B direct connect readiness for $($TenantIds.Count) partner tenant(s)..." "INFO"

    $results = foreach ($tid in $TenantIds) {
        try {
            $p = Get-MgPolicyCrossTenantAccessPolicyPartner -CrossTenantAccessPolicyPartnerId $tid -ErrorAction Stop
            $outboundReady = $p.B2bDirectConnectOutbound.UsersAndGroups.AccessType -eq "allowed"
            $inboundReady  = $p.B2bDirectConnectInbound.UsersAndGroups.AccessType -eq "allowed"

            [PSCustomObject]@{
                PartnerTenantId       = $tid
                YourOutboundConfigured = $outboundReady
                YourInboundConfigured  = $inboundReady
                Note                   = "NEEDS_PARTNER_CONFIRMATION — cannot verify partner tenant's reciprocal config from here"
            }
        }
        catch {
            [PSCustomObject]@{
                PartnerTenantId        = $tid
                YourOutboundConfigured = $false
                YourInboundConfigured  = $false
                Note                   = "NO_PARTNER_OVERRIDE_FOUND — falls back to default policy; check Get-CrossTenantDefaultAudit results"
            }
        }
    }

    return $results
}

# ============================== MAIN ==============================

Write-Status "=== Teams External Access / Guest Access / Shared Channels Audit ===" "INFO"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

try {
    Get-Command Connect-MicrosoftTeams -ErrorAction Stop | Out-Null
}
catch {
    Write-Status "MicrosoftTeams module not found. Install with: Install-Module MicrosoftTeams -Force" "ERROR"
    throw
}

$federationResult   = Get-FederationAudit
$guestInviteResult  = Get-GuestInviteAudit
$crossTenantDefault = Get-CrossTenantDefaultAudit
$partnerOverrides   = Get-CrossTenantPartnerAudit
$guestAccounts      = Get-GuestAccountAudit -StaleDays $StaleInviteDays -DormantDays $DormantGuestDays
$mutualityChecks    = Get-PartnerMutualityCheck -TenantIds $PartnerTenantIds

$federationResult   | Export-Csv (Join-Path $OutputPath "01-FederationConfig.csv") -NoTypeInformation
$guestInviteResult  | Export-Csv (Join-Path $OutputPath "02-GuestInvitePolicy.csv") -NoTypeInformation
$crossTenantDefault | Export-Csv (Join-Path $OutputPath "03-CrossTenantDefault.csv") -NoTypeInformation
$partnerOverrides   | Export-Csv (Join-Path $OutputPath "04-PartnerOverrides.csv") -NoTypeInformation
$guestAccounts      | Export-Csv (Join-Path $OutputPath "05-GuestAccountInventory.csv") -NoTypeInformation
if ($mutualityChecks.Count -gt 0) {
    $mutualityChecks | Export-Csv (Join-Path $OutputPath "06-PartnerMutualityCheck.csv") -NoTypeInformation
}

Write-Status "--- Summary ---" "INFO"
Write-Status "Federation: AllowFederatedUsers=$($federationResult.AllowFederatedUsers), Flag=$($federationResult.Flag)" $(if ($federationResult.Flag -eq "OK") {"OK"} else {"WARN"})
Write-Status "Guest invites: AllowInvitesFrom=$($guestInviteResult.AllowInvitesFrom), Flag=$($guestInviteResult.Flag)" $(if ($guestInviteResult.Flag -eq "OK") {"OK"} else {"WARN"})

$incompleteOverrides = $partnerOverrides | Where-Object Flag -eq "INCOMPLETE_OVERRIDE"
if ($incompleteOverrides.Count -gt 0) {
    Write-Status "$($incompleteOverrides.Count) partner override(s) have incomplete B2B dimension coverage — review 04-PartnerOverrides.csv" "WARN"
}

$staleInvites = $guestAccounts | Where-Object { $_.Flag -match "STALE_PENDING_INVITE" }
$dormantGuests = $guestAccounts | Where-Object { $_.Flag -match "DORMANT_GUEST" }
Write-Status "Guest accounts: $($guestAccounts.Count) total, $($staleInvites.Count) stale pending invites, $($dormantGuests.Count) dormant (90+ days no sign-in)" $(if (($staleInvites.Count + $dormantGuests.Count) -gt 0) {"WARN"} else {"OK"})

if ($mutualityChecks.Count -gt 0) {
    Write-Status "Partner mutuality checks logged for $($mutualityChecks.Count) tenant(s) — partner-side confirmation still required manually" "WARN"
}

Write-Status "Audit complete. Results exported to: $OutputPath" "OK"
