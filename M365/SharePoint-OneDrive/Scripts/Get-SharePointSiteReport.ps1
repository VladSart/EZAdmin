<#
.SYNOPSIS
    Generates a comprehensive SharePoint Online site inventory and health report.

.DESCRIPTION
    Connects to SharePoint Online and exports a detailed report covering:
    - All site collections (teams sites, communication sites, OneDrive)
    - Storage usage vs. quota per site
    - Site owner and secondary owner information
    - Last activity date and sharing settings
    - External sharing status
    - Sites approaching storage quota (configurable threshold)
    - Orphaned sites (no valid owner)

    Output: CSV file with all sites + a summary console report.
    Useful for: storage audits, governance reviews, capacity planning, offboarding cleanup.

.PARAMETER TenantName
    Your Microsoft 365 tenant name (e.g. "contoso" for contoso.sharepoint.com).

.PARAMETER OutputPath
    Directory to save the CSV report. Defaults to the current directory.

.PARAMETER StorageWarningThresholdPct
    Percentage of quota used that triggers a warning flag. Default: 80.

.PARAMETER IncludeOneDrive
    Switch. If specified, includes OneDrive for Business sites in the report.

.PARAMETER IncludePersonalSites
    Switch. Alias for IncludeOneDrive — includes /personal/ URLs.

.PARAMETER SiteTypeFilter
    Filter by site template type: All, TeamSite, CommunicationSite, OneDrive.
    Default: All (excludes OneDrive unless -IncludeOneDrive is set).

.EXAMPLE
    # Basic site report for contoso tenant
    .\Get-SharePointSiteReport.ps1 -TenantName "contoso"

.EXAMPLE
    # Include OneDrive, warn at 90% storage, save to D:\Reports
    .\Get-SharePointSiteReport.ps1 -TenantName "contoso" -IncludeOneDrive `
        -StorageWarningThresholdPct 90 -OutputPath "D:\Reports"

.EXAMPLE
    # Only Communication sites
    .\Get-SharePointSiteReport.ps1 -TenantName "contoso" -SiteTypeFilter "CommunicationSite"

.NOTES
    Requires: PnP.PowerShell module
    Install:  Install-Module PnP.PowerShell -Scope CurrentUser
    Permissions: SharePoint Administrator or Global Administrator
    Authentication: Interactive (MFA-compatible) by default

    Safe to run read-only — makes no changes to any site.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$StorageWarningThresholdPct = 80,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeOneDrive,

    [Parameter(Mandatory = $false)]
    [switch]$IncludePersonalSites,

    [Parameter(Mandatory = $false)]
    [ValidateSet("All", "TeamSite", "CommunicationSite", "OneDrive")]
    [string]$SiteTypeFilter = "All"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helpers

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts][$Status] $Message" -ForegroundColor $colour
}

function Get-SiteType {
    param([string]$Template, [string]$Url)
    if ($Url -match "/personal/") { return "OneDrive" }
    switch -Wildcard ($Template) {
        "GROUP#0"   { return "TeamSite (M365 Group)" }
        "STS#3"     { return "TeamSite (Modern)" }
        "SITEPAGEPUBLISHING#0" { return "CommunicationSite" }
        "TEAMCHANNEL#0" { return "Teams Channel Site" }
        "SPSPERS#10" { return "OneDrive" }
        default     { return $Template }
    }
}

#endregion

#region Preflight

Write-Status "Checking PnP.PowerShell module..."
if (-not (Get-Module -ListAvailable -Name "PnP.PowerShell")) {
    Write-Status "PnP.PowerShell not found. Installing..." "WARN"
    Install-Module PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
}
Import-Module PnP.PowerShell -ErrorAction Stop
Write-Status "PnP.PowerShell loaded." "OK"

# Validate output path
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$csvPath   = Join-Path $OutputPath "SPO-SiteReport-$TenantName-$timestamp.csv"
$adminUrl  = "https://$TenantName-admin.sharepoint.com"

#endregion

#region Connect

Write-Status "Connecting to SharePoint Admin Center: $adminUrl"
try {
    Connect-PnPOnline -Url $adminUrl -Interactive
    Write-Status "Connected." "OK"
} catch {
    Write-Status "Connection failed: $_" "ERROR"
    exit 1
}

#endregion

#region Collect Sites

Write-Status "Retrieving all site collections..."
$includeOD = $IncludeOneDrive -or $IncludePersonalSites

try {
    $allSites = Get-PnPTenantSite -IncludeOneDriveSites:$includeOD -Detailed
    Write-Status "Retrieved $($allSites.Count) site collections." "OK"
} catch {
    Write-Status "Failed to retrieve sites: $_" "ERROR"
    Disconnect-PnPOnline
    exit 1
}

# Apply site type filter
$filteredSites = switch ($SiteTypeFilter) {
    "TeamSite"           { $allSites | Where-Object { $_.Template -match "^GROUP|^STS#3|^TEAMCHANNEL" } }
    "CommunicationSite"  { $allSites | Where-Object { $_.Template -match "SITEPAGEPUBLISHING" } }
    "OneDrive"           { $allSites | Where-Object { $_.Url -match "/personal/" } }
    default              {
        if ($includeOD) { $allSites }
        else { $allSites | Where-Object { $_.Url -notmatch "/personal/" } }
    }
}

Write-Status "Filtered to $($filteredSites.Count) sites after applying type filter '$SiteTypeFilter'."

#endregion

#region Build Report

Write-Status "Building report rows..."
$report       = [System.Collections.Generic.List[PSCustomObject]]::new()
$warnCount    = 0
$orphanCount  = 0
$totalStorage = 0

$i = 0
foreach ($site in $filteredSites) {
    $i++
    if ($i % 50 -eq 0) {
        Write-Status "Processing site $i of $($filteredSites.Count)..."
    }

    # Calculate storage
    $usedGB  = [math]::Round($site.StorageUsageCurrent / 1024, 2)
    $quotaGB = if ($site.StorageMaximumLevel -gt 0) {
        [math]::Round($site.StorageMaximumLevel / 1024, 2)
    } else { $null }

    $pctUsed = if ($quotaGB -and $quotaGB -gt 0) {
        [math]::Round(($usedGB / $quotaGB) * 100, 1)
    } else { $null }

    $storageFlag = if ($pctUsed -and $pctUsed -ge $StorageWarningThresholdPct) {
        $warnCount++
        "WARN: $pctUsed% used"
    } elseif ($pctUsed) {
        "OK: $pctUsed% used"
    } else {
        "No quota set"
    }

    # Owner check
    $ownerLogin = if ($site.Owner) { $site.Owner } else { "NONE" }
    if ($ownerLogin -eq "NONE") { $orphanCount++ }

    $siteType = Get-SiteType -Template $site.Template -Url $site.Url
    $totalStorage += $usedGB

    $row = [PSCustomObject]@{
        Title                = $site.Title
        Url                  = $site.Url
        SiteType             = $siteType
        Template             = $site.Template
        Owner                = $ownerLogin
        StorageUsedGB        = $usedGB
        StorageQuotaGB       = $quotaGB
        StoragePctUsed       = $pctUsed
        StorageFlag          = $storageFlag
        SharingCapability    = $site.SharingCapability
        ExternalSharingEnabled = ($site.SharingCapability -ne "Disabled")
        LastContentModified  = $site.LastContentModifiedDate
        LockState            = $site.LockState
        Status               = $site.Status
    }
    $report.Add($row)
}

Write-Status "Report built: $($report.Count) rows." "OK"

#endregion

#region Export & Summary

$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "CSV exported: $csvPath" "OK"

# Console summary
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SharePoint Site Report — $TenantName" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Total sites:           $($report.Count)"
Write-Host "  Total storage used:    $([math]::Round($totalStorage, 2)) GB"
Write-Host "  Sites near quota:      $warnCount (>= $StorageWarningThresholdPct%)" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Orphaned sites (no owner): $orphanCount" -ForegroundColor $(if ($orphanCount -gt 0) { "Yellow" } else { "Green" })

$externalCount = ($report | Where-Object { $_.ExternalSharingEnabled }).Count
Write-Host "  Sites with external sharing enabled: $externalCount"
Write-Host "  Report saved to: $csvPath" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Show top 5 storage consumers
Write-Host "  Top 5 sites by storage used:" -ForegroundColor Cyan
$report | Sort-Object StorageUsedGB -Descending | Select-Object -First 5 |
    ForEach-Object {
        Write-Host "    $($_.StorageUsedGB) GB  |  $($_.Title)  |  $($_.Url)" -ForegroundColor White
    }
Write-Host ""

# Show storage warnings
if ($warnCount -gt 0) {
    Write-Host "  ⚠ Sites approaching quota (>= $StorageWarningThresholdPct%):" -ForegroundColor Yellow
    $report | Where-Object { $_.StorageFlag -match "WARN" } |
        ForEach-Object {
            Write-Host "    $($_.StoragePctUsed)%  |  $($_.StorageUsedGB)/$($_.StorageQuotaGB) GB  |  $($_.Url)" -ForegroundColor Yellow
        }
    Write-Host ""
}

# Show orphaned sites
if ($orphanCount -gt 0) {
    Write-Host "  ⚠ Orphaned sites (no owner assigned):" -ForegroundColor Yellow
    $report | Where-Object { $_.Owner -eq "NONE" } |
        ForEach-Object {
            Write-Host "    $($_.Title)  |  $($_.Url)" -ForegroundColor Yellow
        }
    Write-Host ""
}

#endregion

#region Cleanup

Disconnect-PnPOnline
Write-Status "Disconnected from SharePoint Online." "OK"

#endregion
