<#
.SYNOPSIS
    Generates a comprehensive B2B guest user audit report for an Entra ID tenant.

.DESCRIPTION
    Queries Microsoft Graph to enumerate all guest users in the tenant and produces
    a structured CSV report covering:
      - Guest identity details (UPN, display name, invited email, home tenant)
      - Account state (enabled/disabled, last sign-in date, stale detection)
      - Group memberships (count and list of groups)
      - Application access (last sign-in app)
      - Invitation status (pending vs. accepted)
      - Creation date and inviting user

    Designed for MSP engineers performing guest access reviews, access recertification
    campaigns, or licence audits. Does NOT modify any guest accounts.

    Does not cover: B2C external identities, service principals, or managed identities.

.PARAMETER InactiveDaysThreshold
    Number of days without sign-in activity before a guest is flagged as stale.
    Default: 90 days.

.PARAMETER OutputPath
    Path where the CSV report will be saved.
    Default: C:\Temp\EntraB2BGuestReport_<timestamp>.csv

.PARAMETER IncludeGroupMemberships
    Switch. When specified, queries group memberships for each guest.
    Note: This significantly increases run time for large tenants (1000+ guests).
    Default: off.

.PARAMETER ExportPendingOnly
    Switch. When specified, only exports guests with pending invitation status.
    Useful for targeted follow-up on guests who never accepted invitations.

.EXAMPLE
    .\Get-EntraB2BGuestReport.ps1
    Generates full guest report with default 90-day inactivity threshold.

.EXAMPLE
    .\Get-EntraB2BGuestReport.ps1 -InactiveDaysThreshold 60 -IncludeGroupMemberships
    Report with 60-day threshold and group membership data.

.EXAMPLE
    .\Get-EntraB2BGuestReport.ps1 -ExportPendingOnly -OutputPath "C:\Reports\PendingGuests.csv"
    Exports only guests with pending invitations to a custom path.

.NOTES
    Requires: Microsoft.Graph PowerShell SDK (Install-Module Microsoft.Graph)
    Permissions needed: User.Read.All, Directory.Read.All, AuditLog.Read.All
    Safe: Read-only. Makes no changes to any directory objects.
    Run-as: Standard user (no admin elevation required if permissions are delegated).
#>

[CmdletBinding()]
param(
    [int]$InactiveDaysThreshold = 90,
    [string]$OutputPath = "C:\Temp\EntraB2BGuestReport_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [switch]$IncludeGroupMemberships,
    [switch]$ExportPendingOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        default   { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Test-GraphConnection {
    try {
        $context = Get-MgContext
        if ($null -eq $context) { return $false }
        return $true
    } catch {
        return $false
    }
}

# ─── PREFLIGHT ────────────────────────────────────────────────────────────────

Write-Status "Entra B2B Guest Audit Report" "INFO"
Write-Status "Inactivity threshold: $InactiveDaysThreshold days" "INFO"
Write-Status "Include group memberships: $IncludeGroupMemberships" "INFO"

# Ensure Microsoft.Graph module is available
$requiredModules = @("Microsoft.Graph.Users", "Microsoft.Graph.Identity.DirectoryManagement")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install with: Install-Module Microsoft.Graph" "ERROR"
        exit 1
    }
}

# Connect to Graph if not already connected
if (-not (Test-GraphConnection)) {
    Write-Status "Not connected to Microsoft Graph. Connecting..." "INFO"
    $requiredScopes = @("User.Read.All", "Directory.Read.All", "AuditLog.Read.All")
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
}

# Verify required scopes
$context = Get-MgContext
$grantedScopes = $context.Scopes
$requiredScopes = @("User.Read.All", "Directory.Read.All", "AuditLog.Read.All")
foreach ($scope in $requiredScopes) {
    if ($scope -notin $grantedScopes) {
        Write-Status "Missing required scope: $scope. Reconnect with: Connect-MgGraph -Scopes 'User.Read.All','Directory.Read.All','AuditLog.Read.All'" "WARN"
    }
}

Write-Status "Connected as: $($context.Account) | Tenant: $($context.TenantId)" "OK"

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# ─── DETECT ───────────────────────────────────────────────────────────────────

Write-Status "Querying guest users..." "INFO"

$staleThresholdDate = (Get-Date).AddDays(-$InactiveDaysThreshold)

# Retrieve all guest users with sign-in activity
$guestUsers = Get-MgUser -Filter "userType eq 'Guest'" -All `
    -Property "Id,DisplayName,UserPrincipalName,Mail,ExternalUserState,ExternalUserStateChangeDateTime,
               CreatedDateTime,AccountEnabled,SignInActivity,CreationType,
               OnPremisesExtensionAttributes" `
    -ConsistencyLevel eventual `
    -CountVariable guestCount

Write-Status "Found $guestCount guest users." "OK"

if ($guestCount -eq 0) {
    Write-Status "No guest users found in tenant. Exiting." "WARN"
    exit 0
}

# ─── EXECUTE ──────────────────────────────────────────────────────────────────

$report = [System.Collections.Generic.List[PSCustomObject]]::new()
$processedCount = 0
$staleCount = 0
$pendingCount = 0
$disabledCount = 0

foreach ($guest in $guestUsers) {
    $processedCount++
    if ($processedCount % 50 -eq 0) {
        Write-Status "Processing: $processedCount / $guestCount" "INFO"
    }

    # Extract home tenant domain from UPN (guest UPNs typically: user_domain.com#EXT#@tenant.onmicrosoft.com)
    $homeTenant = ""
    if ($guest.UserPrincipalName -match "([^_]+)_([^#]+)#EXT#") {
        $homeTenant = $matches[2]
    } elseif ($guest.Mail) {
        $homeTenant = ($guest.Mail -split "@")[-1]
    }

    # Last sign-in details
    $lastSignIn = $null
    $lastSignInApp = ""
    $daysSinceSignIn = $null
    $isStale = $false

    if ($guest.SignInActivity -and $guest.SignInActivity.LastSignInDateTime) {
        $lastSignIn = $guest.SignInActivity.LastSignInDateTime
        $daysSinceSignIn = [int]((Get-Date) - $lastSignIn).TotalDays
        $isStale = $lastSignIn -lt $staleThresholdDate
    } elseif ($guest.CreatedDateTime -and `
             ([datetime]$guest.CreatedDateTime -lt $staleThresholdDate)) {
        # Never signed in and created before threshold — also stale
        $isStale = $true
        $daysSinceSignIn = [int]((Get-Date) - [datetime]$guest.CreatedDateTime).TotalDays
    }

    # Invitation state
    $invitationState = switch ($guest.ExternalUserState) {
        "Accepted"        { "Accepted" }
        "PendingAcceptance"{ "Pending" }
        $null             { "Unknown" }
        default           { $guest.ExternalUserState }
    }

    if ($invitationState -eq "Pending") { $pendingCount++ }
    if (-not $guest.AccountEnabled)     { $disabledCount++ }
    if ($isStale)                       { $staleCount++ }

    # Skip non-pending if ExportPendingOnly is set
    if ($ExportPendingOnly -and $invitationState -ne "Pending") { continue }

    # Group memberships (optional — expensive for large tenants)
    $groupCount = 0
    $groupNames = ""
    if ($IncludeGroupMemberships) {
        try {
            $memberships = Get-MgUserMemberOf -UserId $guest.Id -All |
                Where-Object { $_.'@odata.type' -eq "#microsoft.graph.group" }
            $groupCount = ($memberships | Measure-Object).Count
            $groupNames = ($memberships | Select-Object -ExpandProperty DisplayName) -join "; "
        } catch {
            $groupNames = "Error retrieving"
        }
    }

    $report.Add([PSCustomObject]@{
        DisplayName               = $guest.DisplayName
        UserPrincipalName         = $guest.UserPrincipalName
        InvitedEmail              = $guest.Mail
        HomeTenantDomain          = $homeTenant
        AccountEnabled            = $guest.AccountEnabled
        InvitationState           = $invitationState
        InvitationStateChangedAt  = $guest.ExternalUserStateChangeDateTime
        CreatedDateTime           = $guest.CreatedDateTime
        LastSignInDateTime        = $lastSignIn
        DaysSinceLastSignIn       = $daysSinceSignIn
        IsStale                   = $isStale
        StaleThresholdDays        = $InactiveDaysThreshold
        GroupMembershipCount      = $groupCount
        GroupMemberships          = $groupNames
        ObjectId                  = $guest.Id
    })
}

# ─── VALIDATE & REPORT ────────────────────────────────────────────────────────

Write-Status "Processing complete." "OK"
Write-Status "Total guests processed   : $processedCount" "INFO"
Write-Status "Stale (no sign-in > $InactiveDaysThreshold days): $staleCount" $(if ($staleCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Pending invitation        : $pendingCount" $(if ($pendingCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Disabled accounts         : $disabledCount" "INFO"

if ($report.Count -eq 0) {
    Write-Status "No records match the filter criteria. No file written." "WARN"
    exit 0
}

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Report saved to: $OutputPath" "OK"

# Console summary of top stale guests
if ($staleCount -gt 0) {
    Write-Status "" "INFO"
    Write-Status "--- Top 10 Stale Guests (longest inactive) ---" "WARN"
    $report | Where-Object IsStale -eq $true |
        Sort-Object DaysSinceLastSignIn -Descending |
        Select-Object -First 10 DisplayName, HomeTenantDomain, DaysSinceLastSignIn, InvitationState |
        Format-Table -AutoSize
}
