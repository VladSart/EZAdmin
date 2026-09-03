<#
.SYNOPSIS
    Audits SharePoint Online site collections (and, optionally, OneDrive personal sites) for
    their hero-link default-audience configuration (DefaultMainLinkScope) alongside tenant-wide
    sharing capability settings.

.DESCRIPTION
    Companion script to M365/SharePoint-OneDrive/HeroLinkSharing-B.md and -A.md.

    The "hero link" / third-generation sharing experience (Message Center MC1454378, rolling out
    worldwide late August-late October 2026) introduces a per-site/per-OneDrive DefaultMainLinkScope
    property with NO tenant-wide equivalent. This script sweeps the requested site collections and
    reports:
    - Current DefaultMainLinkScope (OnlyPeopleAdded / Organization) per site
    - Tenant-wide SharingCapability / DefaultSharingLinkType / DefaultLinkPermission (unchanged
      baseline settings that still govern legacy links and external-sharing eligibility)
    - Sites where DefaultMainLinkScope could not be read (older sites / API not yet available /
      site not yet on the new experience) so those can be spot-checked manually

    Does NOT and CANNOT do (no supported API surface exists for this as of this writing):
    - Enumerate the hero-link audience state of individual FILES/FOLDERS (only the site/OneDrive
      level DEFAULT for new items is exposed via DefaultMainLinkScope; an existing item's hero
      link may have since been broadened/narrowed by an end user and is not visible here)
    - Confirm whether a given tenant/site has actually received the staged UI rollout yet (there
      is no PowerShell/Graph flag for this — verify via the Share dialog directly)
    - Enumerate legacy ("Other links") sharing links per item

.PARAMETER AdminUrl
    SharePoint Online admin center URL, e.g. https://contoso-admin.sharepoint.com

.PARAMETER IncludeOneDrive
    Switch. Also enumerates and audits OneDrive personal sites (can be slow on large tenants —
    off by default).

.PARAMETER ExportPath
    Path for CSV export. Default: .\HeroLinkSharingAudit-<timestamp>.csv

.EXAMPLE
    .\Get-HeroLinkSharingAudit.ps1 -AdminUrl https://contoso-admin.sharepoint.com
    Audits all SharePoint site collections' hero-link default-audience configuration.

.EXAMPLE
    .\Get-HeroLinkSharingAudit.ps1 -AdminUrl https://contoso-admin.sharepoint.com -IncludeOneDrive
    Also sweeps OneDrive personal sites.

.NOTES
    Requires: SharePoint Online Management Shell (Microsoft.Online.SharePoint.PowerShell)
    Run-as:   SharePoint Administrator or Global Administrator
    Safe:     Fully read-only. Makes no configuration changes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminUrl,

    [switch]$IncludeOneDrive,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not $ExportPath) {
    $ExportPath = ".\HeroLinkSharingAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
    Write-Status "Microsoft.Online.SharePoint.PowerShell module not found. Install with: Install-Module Microsoft.Online.SharePoint.PowerShell" "ERROR"
    return
}
Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop

Write-Status "Connecting to $AdminUrl ..." "INFO"
try {
    Connect-SPOService -Url $AdminUrl -ErrorAction Stop
} catch {
    Write-Status "Failed to connect: $($_.Exception.Message)" "ERROR"
    return
}

$results = New-Object System.Collections.Generic.List[Object]

Write-Status "Reading tenant-wide sharing settings (baseline, unchanged by hero-link rollout)..." "INFO"
try {
    $tenant = Get-SPOTenant -ErrorAction Stop
    Write-Host ""
    Write-Host "Tenant SharingCapability:     $($tenant.SharingCapability)"
    Write-Host "Tenant DefaultSharingLinkType: $($tenant.DefaultSharingLinkType)"
    Write-Host "Tenant DefaultLinkPermission:  $($tenant.DefaultLinkPermission)"
    Write-Host ""
} catch {
    Write-Status "Could not read tenant sharing settings: $($_.Exception.Message)" "WARN"
}

Write-Status "Enumerating site collections..." "INFO"
$sites = @()
try {
    if ($IncludeOneDrive) {
        $sites = Get-SPOSite -Limit All -IncludePersonalSite $true -ErrorAction Stop
    } else {
        $sites = Get-SPOSite -Limit All -ErrorAction Stop
    }
} catch {
    Write-Status "Failed to enumerate sites: $($_.Exception.Message)" "ERROR"
    return
}

Write-Status "Found $($sites.Count) site(s). Auditing DefaultMainLinkScope..." "INFO"

$scopeMissing = 0
foreach ($site in $sites) {
    $isOneDrive = $site.Url -match "-my\.sharepoint\.com/personal/"
    $entry = [PSCustomObject]@{
        Url                  = $site.Url
        Template             = $site.Template
        IsOneDrive           = $isOneDrive
        DefaultMainLinkScope = $null
        SharingCapability    = $site.SharingCapability
        StorageUsageCurrentMB = $site.StorageUsageCurrent
        ReadError            = $null
        Timestamp            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    try {
        $detail = Get-SPOSite -Identity $site.Url -ErrorAction Stop
        # DefaultMainLinkScope may not exist as a property on older module versions —
        # probe defensively rather than assuming it is always present.
        if ($detail.PSObject.Properties.Name -contains "DefaultMainLinkScope") {
            $entry.DefaultMainLinkScope = $detail.DefaultMainLinkScope
        } else {
            $entry.DefaultMainLinkScope = "PROPERTY-NOT-AVAILABLE"
            $scopeMissing++
        }
    } catch {
        $entry.ReadError = $_.Exception.Message
        $scopeMissing++
    }

    $results.Add($entry)
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host ""
Write-Status "Audit complete. $($results.Count) site(s) processed." "OK"
if ($scopeMissing -gt 0) {
    Write-Status "$scopeMissing site(s) had no readable DefaultMainLinkScope value — either the SPO module predates this property, or the site hasn't received the hero-link rollout yet. Spot-check these manually via the Share dialog." "WARN"
}

$byScope = $results | Where-Object { $_.DefaultMainLinkScope -in @("OnlyPeopleAdded","Organization") } |
    Group-Object DefaultMainLinkScope
foreach ($g in $byScope) {
    Write-Host "  $($g.Name): $($g.Count) site(s)"
}

Write-Status "Full report: $ExportPath" "OK"
Write-Status "Reminder: this script reports the site/OneDrive-level DEFAULT for new items only — it cannot enumerate an individual file's current hero-link audience or any legacy 'Other links' entries. No supported API exists for that as of this writing." "INFO"
