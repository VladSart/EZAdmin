<#
.SYNOPSIS
    Read-only discovery and readiness check for the Project Online (PWA) retirement,
    September 30, 2026.

.DESCRIPTION
    Enumerates every Project Web App (PWA)-enabled site collection in a tenant via
    SharePoint Online Management Shell, reports days remaining against both the
    practical export deadline (2026-09-01) and the hard service cutover
    (2026-09-30), and cross-references Project Online / Project Plan license
    assignments so they can be tracked for manual removal (the subscription does
    NOT auto-cancel when the service retires).

    This script does NOT export, modify, or delete any Project Online project
    data. It is a discovery/tracking tool only, intended to scope the real
    export work (see the official ExportProjectUserContent.ps1 script package
    and this repo's ProjectOnline-Retirement-A.md Playbook 1 for the actual
    per-user/bulk export procedure) and to feed an MSP's fleet-wide tracking
    sheet (Playbook 4).

    What this script CANNOT check (documented limitation, not a bug):
      - Individual project/task/resource counts inside a PWA site (requires
        either the OData API while still live, or PWA Server Settings UI)
      - Whether EPT/governance workflows are still functioning (SharePoint 2013
        workflow dependency broke 2026-04-02, independent of this check)
      - Whether any Power BI/Excel reports depend on the OData feed (no
        tenant-wide discovery surface exists for this; must be asked directly
        of report owners)
      - Whether an informal post-retirement read-only window is currently
        active (unconfirmed by Microsoft, never assume it will be there)

.PARAMETER AdminUrl
    The tenant's SharePoint Online Admin Center URL, e.g.
    https://contoso-admin.sharepoint.com

.PARAMETER ExportCsvPath
    Optional. If provided, writes the PWA site inventory to this CSV path.

.PARAMETER CheckLicenses
    Optional switch. If set, also queries Microsoft Graph for users holding
    Project Online Professional / Premium / Project Plan 3 / Plan 5 licenses.
    Requires the Microsoft.Graph.Users module and an interactive or
    app-based Graph connection already established (Connect-MgGraph) —
    this script does not attempt to establish that connection itself.

.EXAMPLE
    .\Get-ProjectOnlineRetirementReadiness.ps1 -AdminUrl https://contoso-admin.sharepoint.com

.EXAMPLE
    .\Get-ProjectOnlineRetirementReadiness.ps1 -AdminUrl https://contoso-admin.sharepoint.com `
        -ExportCsvPath C:\Reports\ProjectOnline-Inventory.csv -CheckLicenses

.NOTES
    Requires: SharePoint Online Management Shell (Microsoft.Online.SharePoint.PowerShell)
    Run-as: A SharePoint administrator account for the target tenant.
    Optional: Microsoft.Graph.Users module + an active Connect-MgGraph session
              if -CheckLicenses is used.
    Safe/unsafe: Fully read-only. Makes no changes to Project Online, SharePoint,
                 or license assignments.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminUrl,

    [Parameter(Mandatory = $false)]
    [string]$ExportCsvPath,

    [Parameter(Mandatory = $false)]
    [switch]$CheckLicenses
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Project Online Retirement Readiness Check — starting" "INFO"

if (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
    Write-Status "SharePoint Online Management Shell module not found. Install with:" "ERROR"
    Write-Status "  Install-Module -Name Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser" "ERROR"
    return
}
Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop -DisableNameChecking

# ---------------------------------------------------------------------------
# Deadline math (hardcoded to the confirmed Message Center MC812729 timeline —
# update only if Microsoft publishes a revised date)
# ---------------------------------------------------------------------------
$exportDeadline = Get-Date "2026-09-01"
$hardCutover    = Get-Date "2026-09-30"
$today          = Get-Date

$daysToExport  = [math]::Round(($exportDeadline - $today).TotalDays, 1)
$daysToCutover = [math]::Round(($hardCutover - $today).TotalDays, 1)

Write-Status "Today: $($today.ToString('yyyy-MM-dd'))" "INFO"

if ($today -gt $hardCutover) {
    Write-Status "Hard cutover (2026-09-30) has already passed. Project Online is retired." "ERROR"
    Write-Status "If unexported data is discovered now, see ProjectOnline-Retirement-B.md Fix 7." "ERROR"
} elseif ($today -gt $exportDeadline) {
    Write-Status "Practical export deadline (2026-09-01) has passed. $daysToCutover day(s) remain to hard cutover." "WARN"
    Write-Status "Treat every unexported tenant found below as an ACTIVE, URGENT risk, not a routine finding." "WARN"
} else {
    Write-Status "$daysToExport day(s) remain to the practical export deadline (2026-09-01)." "OK"
    Write-Status "$daysToCutover day(s) remain to the hard service cutover (2026-09-30)." "INFO"
}

# ---------------------------------------------------------------------------
# Connect and enumerate PWA sites
# ---------------------------------------------------------------------------
try {
    Write-Status "Connecting to $AdminUrl ..." "INFO"
    Connect-SPOService -Url $AdminUrl
} catch {
    Write-Status "Failed to connect to SharePoint Online Admin Center: $($_.Exception.Message)" "ERROR"
    return
}

Write-Status "Enumerating PWA-enabled site collections ..." "INFO"
try {
    $allSites = Get-SPOSite -Limit All
} catch {
    Write-Status "Failed to enumerate site collections: $($_.Exception.Message)" "ERROR"
    return
}

$pwaSites = $allSites | Where-Object { $_.PWAEnabled -eq "Enabled" }

if ($pwaSites.Count -eq 0) {
    Write-Status "No PWA-enabled site collections found. No Project Online migration action appears needed for this tenant." "OK"
    Write-Status "If the client insists they use Project Online, confirm the exact URL manually — some tenants" "WARN"
    Write-Status "  rename or move PWA sites in ways that can affect the PWAEnabled property detection." "WARN"
} else {
    Write-Status "Found $($pwaSites.Count) PWA-enabled site collection(s):" "WARN"
    $pwaSites | Select-Object Url, Owner, StorageUsageCurrent, LastContentModifiedDate |
        Format-Table -AutoSize | Out-String | Write-Host
}

# ---------------------------------------------------------------------------
# Optional: license cross-reference
# ---------------------------------------------------------------------------
$licenseResults = @()
if ($CheckLicenses) {
    Write-Status "Checking Project Online / Project Plan license assignments via Microsoft Graph ..." "INFO"

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
        Write-Status "Microsoft.Graph.Users module not found. Install with:" "ERROR"
        Write-Status "  Install-Module -Name Microsoft.Graph.Users -Scope CurrentUser" "ERROR"
    } else {
        Import-Module Microsoft.Graph.Users -ErrorAction SilentlyContinue

        # These SKU part number substrings cover Project Online Professional/Premium
        # and their Project Plan 3/5 successor naming. Verify against your own
        # tenant's Get-MgSubscribedSku output — Microsoft's SKU naming has drifted
        # over the product's lifetime and this list is not guaranteed exhaustive.
        $projectSkuPatterns = @(
            "PROJECTPROFESSIONAL", "PROJECTPREMIUM", "PROJECT_P3", "PROJECT_P5",
            "PROJECTPLAN3", "PROJECTPLAN5", "PROJECT_CLIENT_SUBSCRIPTION"
        )

        try {
            $skus = Get-MgSubscribedSku -All -ErrorAction Stop
            $matchingSkus = $skus | Where-Object {
                $skuName = $_.SkuPartNumber
                $projectSkuPatterns | Where-Object { $skuName -like "*$_*" }
            }

            if ($matchingSkus.Count -eq 0) {
                Write-Status "No Project Online / Project Plan SKUs found in this tenant's subscribed SKU list." "OK"
                Write-Status "Verify manually against 'Get-MgSubscribedSku | Select SkuPartNumber' if this seems unexpected —" "WARN"
                Write-Status "  the pattern list above is not guaranteed to match every historical SKU naming variant." "WARN"
            } else {
                foreach ($sku in $matchingSkus) {
                    Write-Status "SKU: $($sku.SkuPartNumber) — Assigned: $($sku.ConsumedUnits) / $($sku.PrepaidUnits.Enabled)" "WARN"
                    $usersWithSku = Get-MgUser -All -Property "DisplayName,UserPrincipalName,AssignedLicenses,AccountEnabled" |
                        Where-Object { $_.AssignedLicenses.SkuId -contains $sku.SkuId }

                    foreach ($u in $usersWithSku) {
                        $licenseResults += [PSCustomObject]@{
                            SkuPartNumber     = $sku.SkuPartNumber
                            UserPrincipalName = $u.UserPrincipalName
                            DisplayName       = $u.DisplayName
                            AccountEnabled    = $u.AccountEnabled
                        }
                    }
                }

                $disabledWithLicense = $licenseResults | Where-Object { -not $_.AccountEnabled }
                if ($disabledWithLicense.Count -gt 0) {
                    Write-Status "$($disabledWithLicense.Count) DISABLED account(s) still hold a Project Online/Project Plan license — priority cleanup candidates:" "WARN"
                    $disabledWithLicense | Format-Table -AutoSize | Out-String | Write-Host
                }
            }
        } catch {
            Write-Status "Graph license check failed: $($_.Exception.Message)" "ERROR"
            Write-Status "Confirm Connect-MgGraph has been run with at least User.Read.All + Organization.Read.All scopes." "ERROR"
        }
    }
}

# ---------------------------------------------------------------------------
# Report / export
# ---------------------------------------------------------------------------
$summary = [PSCustomObject]@{
    RunDate                = $today.ToString('yyyy-MM-dd')
    PWASitesFound           = $pwaSites.Count
    DaysToExportDeadline    = $daysToExport
    DaysToHardCutover       = $daysToCutover
    ExportDeadlinePassed    = $today -gt $exportDeadline
    HardCutoverPassed       = $today -gt $hardCutover
    ProjectLicensesFound    = $licenseResults.Count
    DisabledAccountsWithLicense = ($licenseResults | Where-Object { -not $_.AccountEnabled }).Count
}

Write-Status "Summary:" "INFO"
$summary | Format-List | Out-String | Write-Host

if ($ExportCsvPath) {
    try {
        $pwaSites | Select-Object Url, Owner, StorageUsageCurrent, LastContentModifiedDate |
            Export-Csv -Path $ExportCsvPath -NoTypeInformation -Force
        Write-Status "PWA site inventory exported to $ExportCsvPath" "OK"

        if ($licenseResults.Count -gt 0) {
            $licenseCsvPath = $ExportCsvPath -replace '\.csv$', '-Licenses.csv'
            $licenseResults | Export-Csv -Path $licenseCsvPath -NoTypeInformation -Force
            Write-Status "License assignment detail exported to $licenseCsvPath" "OK"
        }
    } catch {
        Write-Status "Failed to export CSV: $($_.Exception.Message)" "ERROR"
    }
}

Write-Status "Readiness check complete. This script performed NO exports of project data —" "INFO"
Write-Status "see ProjectOnline-Retirement-A.md Playbook 1 for the actual per-user/bulk export procedure." "INFO"
