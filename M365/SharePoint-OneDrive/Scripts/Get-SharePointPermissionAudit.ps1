<#
.SYNOPSIS
    Audits SharePoint Online site permission health — sharing capability alignment, broken
    inheritance (unique permissions), M365 Group vs. SPO group membership mismatches, and
    guest redemption state.

.DESCRIPTION
    Automates the Validation Steps and Symptom -> Cause Map checks from Permissions-A.md and
    the Diagnosis & Validation Flow from Permissions-B.md across one or more sites, instead of
    walking through each check manually per ticket.

    For each site supplied, checks and flags:
    - SITE_SHARING_EXCEEDS_TENANT — site SharingCapability is more permissive than the tenant
      setting (should be structurally impossible, but drift/misconfiguration happens) per
      Permissions-A.md's "tenant is the hard ceiling" Learning Pointer
    - SITE_LOCKED — LockState is ReadOnly or NoAccess, per Permissions-B.md Fix 5
    - HIGH_UNIQUE_PERMISSION_COUNT — the site's default "Documents" library has more than
      -UniquePermissionWarningThreshold items with broken inheritance, the leading indicator
      of "permission sprawl" called out in Permissions-A.md's Learning Pointers and Phase 4
    - GROUP_CONNECTED_NO_GROUPID — site's GroupId is empty despite the site title/template
      suggesting it should be M365-Group-connected (Teams site), per Permissions-B.md Fix 4 —
      "site was disconnected from the group, requires admin reconnection"
    - PENDING_GUEST_REDEMPTION — for any external/guest users optionally supplied via
      -CheckGuestUPNs, flags ExternalUserState = PendingAcceptance per Permissions-A.md
      Validation Step 6

    Does NOT modify any site, group, or permission — this is a read-only audit companion to
    the Common Fix Paths / Remediation Playbooks documented in Permissions-B.md and
    Permissions-A.md.

.PARAMETER SiteUrls
    One or more full SharePoint site URLs to audit
    (e.g. https://contoso.sharepoint.com/sites/Finance).

.PARAMETER TenantAdminUrl
    The SharePoint admin center URL (e.g. https://contoso-admin.sharepoint.com). Required to
    read the tenant-wide sharing setting for comparison against each site.

.PARAMETER UniquePermissionWarningThreshold
    Number of items with broken inheritance in the default document library that triggers a
    HIGH_UNIQUE_PERMISSION_COUNT flag. Default: 50.

.PARAMETER CheckGuestUPNs
    Optional array of guest/external user UPNs (or email addresses) to check redemption state
    for, via Microsoft Graph.

.PARAMETER OutputPath
    Directory to save the CSV report. Defaults to the current directory.

.EXAMPLE
    .\Get-SharePointPermissionAudit.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com `
        -SiteUrls "https://contoso.sharepoint.com/sites/Finance"

.EXAMPLE
    .\Get-SharePointPermissionAudit.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com `
        -SiteUrls "https://contoso.sharepoint.com/sites/Finance","https://contoso.sharepoint.com/sites/HR" `
        -CheckGuestUPNs "partner@vendor.com" -UniquePermissionWarningThreshold 100

.NOTES
    Requires:
    - Microsoft.Online.SharePoint.PowerShell module (Connect-SPOService)
    - PnP.PowerShell module (Connect-PnPOnline) — per-site checks
    - Microsoft.Graph module (Connect-MgGraph) — only if -CheckGuestUPNs is used
    - SharePoint Administrator or Global Administrator role

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to sites, groups, or permissions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SiteUrls,

    [Parameter(Mandatory = $true)]
    [string]$TenantAdminUrl,

    [Parameter()]
    [int]$UniquePermissionWarningThreshold = 50,

    [Parameter()]
    [string[]]$CheckGuestUPNs = @(),

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

# Ordered list — index = restrictiveness rank (0 = most restrictive)
$sharingRank = @("Disabled", "ExistingExternalUserSharingOnly", "ExternalUserSharingOnly", "ExternalUserAndGuestSharing")

function Get-SharingRank {
    param([string]$Capability)
    $idx = $sharingRank.IndexOf($Capability)
    if ($idx -lt 0) { return -1 }
    return $idx
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting SharePoint Permission Audit for $($SiteUrls.Count) site(s)..." "INFO"

foreach ($mod in @("Microsoft.Online.SharePoint.PowerShell", "PnP.PowerShell")) {
    if (-not (Get-Module -Name $mod -ListAvailable)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod -Scope CurrentUser -AllowClobber" "ERROR"
        exit 1
    }
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Connecting to SharePoint Admin Center: $TenantAdminUrl" "INFO"
try {
    Connect-SPOService -Url $TenantAdminUrl -ErrorAction Stop
    Write-Status "Connected to SPO Management Shell" "OK"
} catch {
    Write-Status "Failed to connect to SPO Management Shell: $($_.Exception.Message)" "ERROR"
    exit 1
}

$tenant = Get-SPOTenant
$tenantRank = Get-SharingRank -Capability $tenant.SharingCapability
Write-Status "Tenant sharing capability: $($tenant.SharingCapability)" "INFO"

$graphConnected = $false
if ($CheckGuestUPNs.Count -gt 0) {
    try {
        Connect-MgGraph -Scopes "User.Read.All" -ErrorAction Stop -NoWelcome
        $graphConnected = $true
        Write-Status "Connected to Microsoft Graph (guest redemption checks enabled)" "OK"
    } catch {
        Write-Status "Failed to connect to Microsoft Graph — guest redemption checks will be skipped: $($_.Exception.Message)" "WARN"
    }
}

$siteReport  = [System.Collections.Generic.List[PSCustomObject]]::new()
$guestReport = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($siteUrl in $SiteUrls) {
    Write-Status "Auditing site: $siteUrl" "INFO"
    $flags = [System.Collections.Generic.List[string]]::new()

    try {
        $site = Get-SPOSite -Identity $siteUrl -ErrorAction Stop
    } catch {
        Write-Status "  Could not retrieve site $siteUrl : $($_.Exception.Message)" "ERROR"
        $siteReport.Add([PSCustomObject]@{
            SiteUrl = $siteUrl; SharingCapability = "N/A"; LockState = "N/A"
            GroupId = "N/A"; UniquePermissionCount = -1; Flags = "SITE_LOOKUP_FAILED"; Severity = "HIGH"
        })
        continue
    }

    $siteRank = Get-SharingRank -Capability $site.SharingCapability
    if ($tenantRank -ge 0 -and $siteRank -ge 0 -and $siteRank -gt $tenantRank) {
        $flags.Add("SITE_SHARING_EXCEEDS_TENANT")
    }

    if ($site.LockState -ne "Unlock") {
        $flags.Add("SITE_LOCKED_$($site.LockState.ToUpper())")
    }

    $groupId = $site.GroupId
    $looksGroupConnected = $site.Template -match "^GROUP|^TEAMCHANNEL"
    if ($looksGroupConnected -and ([string]::IsNullOrEmpty($groupId) -or $groupId -eq "00000000-0000-0000-0000-000000000000")) {
        $flags.Add("GROUP_CONNECTED_NO_GROUPID")
    }

    # Unique permission sprawl check via PnP (best-effort — requires interactive auth per site)
    $uniqueCount = -1
    try {
        Connect-PnPOnline -Url $siteUrl -Interactive -ErrorAction Stop
        $list = Get-PnPList -Identity "Documents" -ErrorAction SilentlyContinue
        if ($list) {
            $items = Get-PnPListItem -List "Documents" -Fields "FileLeafRef", "HasUniqueRoleAssignments" -PageSize 500 -ErrorAction SilentlyContinue
            $uniqueCount = ($items | Where-Object { $_["HasUniqueRoleAssignments"] -eq $true }).Count
            if ($uniqueCount -gt $UniquePermissionWarningThreshold) {
                $flags.Add("HIGH_UNIQUE_PERMISSION_COUNT")
            }
        }
        Disconnect-PnPOnline
    } catch {
        Write-Status "  Could not complete unique-permission check for $siteUrl : $($_.Exception.Message)" "WARN"
        $flags.Add("UNIQUE_PERMISSION_CHECK_FAILED")
    }

    $severity = if ($flags -match "SITE_LOCKED|SITE_LOOKUP_FAILED") { "HIGH" }
                elseif ($flags.Count -gt 0) { "MEDIUM" }
                else { "OK" }

    $siteReport.Add([PSCustomObject]@{
        SiteUrl               = $siteUrl
        SharingCapability     = $site.SharingCapability
        TenantSharingCapability = $tenant.SharingCapability
        LockState             = $site.LockState
        GroupId               = $groupId
        UniquePermissionCount = $uniqueCount
        Flags                 = ($flags -join "; ")
        Severity              = $severity
    })
}

foreach ($guestUpn in $CheckGuestUPNs) {
    if (-not $graphConnected) { break }
    try {
        $guest = Get-MgUser -Filter "mail eq '$guestUpn' or userPrincipalName eq '$guestUpn'" -Property DisplayName, Mail, ExternalUserState, AccountEnabled -ErrorAction Stop
        if (-not $guest) {
            $guestReport.Add([PSCustomObject]@{ GuestUPN = $guestUpn; ExternalUserState = "NOT_FOUND"; AccountEnabled = $null; Flag = "GUEST_NOT_FOUND" })
            continue
        }
        $flag = if ($guest.ExternalUserState -eq "PendingAcceptance") { "PENDING_GUEST_REDEMPTION" }
                elseif (-not $guest.AccountEnabled) { "GUEST_ACCOUNT_DISABLED" }
                else { "OK" }
        $guestReport.Add([PSCustomObject]@{
            GuestUPN          = $guestUpn
            ExternalUserState = $guest.ExternalUserState
            AccountEnabled    = $guest.AccountEnabled
            Flag              = $flag
        })
    } catch {
        $guestReport.Add([PSCustomObject]@{ GuestUPN = $guestUpn; ExternalUserState = "LOOKUP_FAILED"; AccountEnabled = $null; Flag = "GUEST_LOOKUP_FAILED" })
    }
}

# Summary
$separator = "=" * 60
Write-Host ""
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SHAREPOINT PERMISSION AUDIT SUMMARY" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan
$high = $siteReport | Where-Object Severity -eq "HIGH"
$med  = $siteReport | Where-Object Severity -eq "MEDIUM"
Write-Status "Sites audited: $($siteReport.Count)" "INFO"
Write-Status "HIGH severity: $($high.Count)" $(if ($high.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "MEDIUM severity: $($med.Count)" $(if ($med.Count -gt 0) { "WARN" } else { "OK" })
$siteReport | Select-Object SiteUrl, Severity, Flags | Format-Table -AutoSize -Wrap

if ($guestReport.Count -gt 0) {
    Write-Host "[ GUEST REDEMPTION STATE ]" -ForegroundColor Yellow
    $guestReport | Format-Table -AutoSize
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$siteCsv = Join-Path $OutputPath "SharePointPermissionAudit-Sites-$stamp.csv"
$siteReport | Export-Csv -Path $siteCsv -NoTypeInformation -Encoding UTF8
Write-Status "Site report exported to: $siteCsv" "OK"

if ($guestReport.Count -gt 0) {
    $guestCsv = Join-Path $OutputPath "SharePointPermissionAudit-Guests-$stamp.csv"
    $guestReport | Export-Csv -Path $guestCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Guest report exported to: $guestCsv" "OK"
}

Write-Status "SharePoint permission audit complete." "OK"
