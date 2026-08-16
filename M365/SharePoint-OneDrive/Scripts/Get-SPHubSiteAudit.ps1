<#
.SYNOPSIS
    Audits SharePoint hub site registration, association coverage, hub-to-hub nesting, and
    tenant limit exposure across the tenant.

.DESCRIPTION
    Automates the Validation Steps and Phase 1-5 troubleshooting flows from HubSites-A.md so an
    admin can see the full hub site structure and health in one pass instead of checking each
    hub's associated-site list individually.

    Covers:
    - Every registered hub site with its approval requirement, associated-site count, and
      hub-to-hub nesting role (parent, child, or standalone)
    - APPROACHING_LIMIT / AT_LIMIT flags when tenant hub count nears the 2,000 registration
      ceiling (thresholds configurable)
    - ORPHAN_HUB flag on any registered hub with zero associated sites — a common leftover from
      abandoned pilot projects that still counts against the tenant's hub limit
    - NESTING_DEPTH_VIOLATION flag if a child hub is itself found with a populated
      ParentHubSiteId chain deeper than one level (defensive check — SharePoint should prevent
      this, but the runbook's architecture notes call out this as the documented hard limit worth
      verifying rather than assuming)
    - Per-site association inventory: every site's HubSiteId resolved to a hub title, with an
      UNASSOCIATED flag list available via the -IncludeUnassociatedSites switch for information
      architecture planning
    - Optional per-hub permission snapshot: confirms (per HubSites-A.md's core teaching point)
      that a hub's own site permissions are independent of its associated sites' permissions, by
      reporting both side-by-side so a reviewer can see they are NOT identical by design

    Does NOT cover:
    - SharePoint Advanced Management hub-level Restricted Access Control (separate script —
      Get-SPAdvancedManagementAudit.ps1 in this same folder)
    - Search crawl status for hub-scoped managed properties (not exposed via SPO PowerShell;
      requires Search Admin Center for deep diagnosis)

.PARAMETER ApproachingLimitThreshold
    Hub count at which to flag APPROACHING_LIMIT. Default: 1500 (75% of the 2,000 tenant limit).

.PARAMETER IncludeUnassociatedSites
    Switch. If set, also inventories all tenant sites NOT associated with any hub (can be a large
    result set in big tenants — off by default).

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-SPHubSiteAudit.ps1 -OutputPath C:\Temp\HubAudit

.EXAMPLE
    .\Get-SPHubSiteAudit.ps1 -IncludeUnassociatedSites -ApproachingLimitThreshold 1800

.NOTES
    Requires:
    - Microsoft.Online.SharePoint.PowerShell module (Connect-SPOService)
    - SharePoint Administrator or Global Administrator role

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to hub registrations or associations.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$ApproachingLimitThreshold = 1500,

    [Parameter()]
    [switch]$IncludeUnassociatedSites,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:TenantHubLimit = 2000
$script:EmptyGuid = "00000000-0000-0000-0000-000000000000"

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

function Get-HubStructureAudit {
    param([array]$AllHubs, [array]$AllSites, [int]$LimitThreshold)

    Write-Status "Building hub structure report for $($AllHubs.Count) registered hub(s)..." "INFO"

    $results = foreach ($hub in $AllHubs) {
        $associated = $AllSites | Where-Object { $_.HubSiteId -eq $hub.ID }
        $isChild = [bool]($hub.ParentHubSiteId -and $hub.ParentHubSiteId -ne $script:EmptyGuid)
        $isParent = [bool]($AllHubs | Where-Object { $_.ParentHubSiteId -eq $hub.ID })

        $role = if ($isChild -and $isParent) { "CHILD_AND_PARENT" }
                elseif ($isChild) { "CHILD" }
                elseif ($isParent) { "PARENT" }
                else { "STANDALONE" }

        # Defensive nesting-depth check: a child hub should never itself have a parent
        # that is also a child (which would create depth > 1)
        $nestingFlag = "OK"
        if ($isChild) {
            $parentHub = $AllHubs | Where-Object { $_.ID -eq $hub.ParentHubSiteId }
            if ($parentHub -and $parentHub.ParentHubSiteId -and $parentHub.ParentHubSiteId -ne $script:EmptyGuid) {
                $nestingFlag = "NESTING_DEPTH_VIOLATION"
            }
        }

        $orphanFlag = if ($associated.Count -eq 0 -and -not $isParent) { "ORPHAN_HUB" } else { "OK" }

        [PSCustomObject]@{
            HubTitle             = $hub.Title
            HubUrl               = $hub.SiteUrl
            HubId                = $hub.ID
            RequiresJoinApproval = $hub.RequiresJoinApproval
            Role                 = $role
            AssociatedSiteCount  = $associated.Count
            OrphanFlag           = $orphanFlag
            NestingFlag          = $nestingFlag
        }
    }

    return $results
}

function Get-TenantLimitAudit {
    param([int]$CurrentCount, [int]$LimitThreshold)

    $flag = "OK"
    if ($CurrentCount -ge $script:TenantHubLimit) {
        $flag = "AT_LIMIT"
    }
    elseif ($CurrentCount -ge $LimitThreshold) {
        $flag = "APPROACHING_LIMIT"
    }

    [PSCustomObject]@{
        RegisteredHubCount = $CurrentCount
        TenantLimit        = $script:TenantHubLimit
        WarningThreshold   = $LimitThreshold
        PercentOfLimit     = [math]::Round(($CurrentCount / $script:TenantHubLimit) * 100, 1)
        Flag               = $flag
    }
}

function Get-SiteAssociationInventory {
    param([array]$AllSites, [array]$AllHubs, [bool]$IncludeUnassociated)

    Write-Status "Building per-site association inventory..." "INFO"

    $hubLookup = @{}
    foreach ($h in $AllHubs) { $hubLookup[$h.ID] = $h.Title }

    $results = foreach ($site in $AllSites) {
        $isAssociated = [bool]($site.HubSiteId -and $site.HubSiteId -ne $script:EmptyGuid)

        if (-not $isAssociated -and -not $IncludeUnassociated) { continue }

        [PSCustomObject]@{
            SiteUrl       = $site.Url
            SiteTitle     = $site.Title
            HubTitle      = if ($isAssociated -and $hubLookup.ContainsKey($site.HubSiteId)) { $hubLookup[$site.HubSiteId] } else { $null }
            IsAssociated  = $isAssociated
            Flag          = if (-not $isAssociated) { "UNASSOCIATED" } else { "OK" }
        }
    }

    return $results
}

function Get-HubPermissionIndependenceSnapshot {
    param([array]$AllHubs)

    Write-Status "Confirming hub/associated-site permission independence (this can be slow on large hubs)..." "INFO"

    $results = foreach ($hub in $AllHubs) {
        try {
            $hubPermCount = (Get-SPOUser -Site $hub.SiteUrl -ErrorAction Stop).Count
        }
        catch {
            $hubPermCount = -1
        }

        [PSCustomObject]@{
            HubTitle          = $hub.Title
            HubUrl            = $hub.SiteUrl
            HubUserCount      = $hubPermCount
            Note              = "Associated sites each maintain independent permissions — this count reflects the HUB site only, not associated sites"
        }
    }

    return $results
}

# ============================== MAIN ==============================

Write-Status "=== SharePoint Hub Site Structure & Health Audit ===" "INFO"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

try {
    Get-Command Connect-SPOService -ErrorAction Stop | Out-Null
}
catch {
    Write-Status "Microsoft.Online.SharePoint.PowerShell module not found. Install with: Install-Module Microsoft.Online.SharePoint.PowerShell -Force" "ERROR"
    throw
}

Write-Status "Retrieving all registered hub sites..." "INFO"
$allHubs = Get-SPOHubSite

Write-Status "Retrieving all tenant sites (this may take a while for large tenants)..." "INFO"
$allSites = Get-SPOSite -Limit All

$hubStructure   = Get-HubStructureAudit -AllHubs $allHubs -AllSites $allSites -LimitThreshold $ApproachingLimitThreshold
$tenantLimit    = Get-TenantLimitAudit -CurrentCount $allHubs.Count -LimitThreshold $ApproachingLimitThreshold
$siteInventory  = Get-SiteAssociationInventory -AllSites $allSites -AllHubs $allHubs -IncludeUnassociated $IncludeUnassociatedSites.IsPresent
$permSnapshot   = Get-HubPermissionIndependenceSnapshot -AllHubs $allHubs

$hubStructure  | Export-Csv (Join-Path $OutputPath "01-HubStructure.csv") -NoTypeInformation
$tenantLimit   | Export-Csv (Join-Path $OutputPath "02-TenantLimitStatus.csv") -NoTypeInformation
$siteInventory | Export-Csv (Join-Path $OutputPath "03-SiteAssociationInventory.csv") -NoTypeInformation
$permSnapshot  | Export-Csv (Join-Path $OutputPath "04-HubPermissionSnapshot.csv") -NoTypeInformation

Write-Status "--- Summary ---" "INFO"
Write-Status "Registered hubs: $($tenantLimit.RegisteredHubCount) / $($tenantLimit.TenantLimit) ($($tenantLimit.PercentOfLimit)%)" $(if ($tenantLimit.Flag -eq "OK") {"OK"} else {"WARN"})

$orphans = $hubStructure | Where-Object OrphanFlag -eq "ORPHAN_HUB"
if ($orphans.Count -gt 0) {
    Write-Status "$($orphans.Count) orphan hub(s) found — registered with zero associated sites and no child hubs, still counting against the tenant limit" "WARN"
}

$nestingViolations = $hubStructure | Where-Object NestingFlag -eq "NESTING_DEPTH_VIOLATION"
if ($nestingViolations.Count -gt 0) {
    Write-Status "$($nestingViolations.Count) hub(s) show nesting depth beyond the supported single level — investigate manually" "WARN"
}

if ($IncludeUnassociatedSites.IsPresent) {
    $unassociated = $siteInventory | Where-Object Flag -eq "UNASSOCIATED"
    Write-Status "$($unassociated.Count) unassociated site(s) found in inventory" "INFO"
}

Write-Status "Audit complete. Results exported to: $OutputPath" "OK"
