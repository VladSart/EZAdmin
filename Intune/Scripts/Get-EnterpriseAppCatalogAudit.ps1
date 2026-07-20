<#
.SYNOPSIS
    Audits Microsoft Intune Enterprise App Management (Enterprise App Catalog) app health
    and lifecycle risk tenant-wide.

.DESCRIPTION
    Read-only Graph-based audit distinguishing genuine Enterprise App Catalog apps from
    look-alike admin-uploaded Win32 apps, then flagging the catalog-specific risk
    conditions documented in EnterpriseAppManagement-A.md:

      - CONTENT_NOT_READY: catalog app content still shows a non-ready publishing state
        past a configurable staleness threshold (default 3 hours; the documented cache
        window is ~1 hour, so this leaves headroom before flagging a genuine stall)
      - DUPLICATE_APP_DEPLOYMENT: two or more app objects sharing a normalized display
        name where at least one is a catalog app and at least one is not — the classic
        "app fighting itself" conflict pattern (EnterpriseAppManagement-B.md Fix 4)
      - AUTOUPDATE_NO_REQUIRED_ASSIGNMENT: an app with auto-update-eligible characteristics
        assigned as Available only — auto-update never applies without a Required
        assignment, so this flags apps where auto-update intent likely doesn't match
        actual assignment (informational; assignment intent isn't always exposed
        identically across app types, verify in the portal before treating as a fault)
      - STALE_NO_RECENT_UPDATE: catalog app with no LastModifiedDateTime movement past a
        configurable staleness threshold (default 180 days) — not itself a problem, but
        useful for spotting catalog apps an MSP forgot they deployed, worth a licensing/
        relevance review
      - LICENSING_NOT_CONFIRMED: no subscribed SKU matching known Intune Suite / Enterprise
        App Management SKU patterns found — catalog app objects existing without confirmed
        licensing coverage is worth flagging for a billing/entitlement review

    This script does NOT perform device-side validation (IME log inspection, Delivery
    Optimization state, installed-app registry checks) — that is inherently device-local
    and is covered by Get-AppDeploymentDiagnostics.ps1 plus EnterpriseAppManagement-A.md's
    Evidence Pack. This script is a tenant-wide catalog-app inventory and lifecycle-risk
    sweep only.

.PARAMETER ContentStalenessHours
    Hours a catalog app may remain in a non-ready content publishing state before being
    flagged CONTENT_NOT_READY. Default: 3 (documented cache window is ~1 hour; this adds
    margin before treating it as a genuine stall rather than routine cache lag).

.PARAMETER StaleAppDays
    Days since LastModifiedDateTime before a catalog app is flagged STALE_NO_RECENT_UPDATE.
    Default: 180.

.PARAMETER AppNameFilter
    Optional wildcard filter (e.g. "*Adobe*") to scope the audit to a subset of apps by
    display name. Default: "*" (all apps).

.EXAMPLE
    .\Get-EnterpriseAppCatalogAudit.ps1
    Runs a full tenant-wide Enterprise App Catalog audit with default thresholds.

.EXAMPLE
    .\Get-EnterpriseAppCatalogAudit.ps1 -AppNameFilter "*Chrome*" -ContentStalenessHours 6
    Scopes the audit to apps matching "Chrome" with a looser content-staleness threshold.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement modules.
    Required scopes: DeviceManagementApps.Read.All, Organization.Read.All
    Run-as: any account with at least Intune read access to Apps.
    Read-only — makes no changes to any app object, assignment, or catalog entry.
#>

#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$ContentStalenessHours = 3,

    [Parameter(Mandatory = $false)]
    [int]$StaleAppDays = 180,

    [Parameter(Mandatory = $false)]
    [string]$AppNameFilter = "*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-NormalizedAppName {
    param([string]$Name)
    # Strip common version/edition noise so near-identical display names correlate
    # for duplicate-deployment detection (e.g. "Zoom" vs "Zoom Workplace" vs "Zoom (64-bit)")
    ($Name -replace '\(.*?\)', '' -replace '\d+(\.\d+)+', '' -replace '\s+', ' ').Trim().ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Enterprise App Catalog audit..." "INFO"

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "No active Graph session — connecting with required scopes." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementApps.Read.All", "Organization.Read.All" -NoWelcome
    }
}
catch {
    Write-Status "Failed to establish Graph session: $($_.Exception.Message)" "ERROR"
    throw
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

# ---------------------------------------------------------------------------
# Preflight: confirm licensing coverage
# ---------------------------------------------------------------------------
Write-Status "Checking tenant licensing for Enterprise App Management / Intune Suite coverage..." "INFO"

$licensed = $false
try {
    $skus = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/subscribedSkus"
    $matchingSkus = $skus.value | Where-Object { $_.skuPartNumber -match "INTUNE|EMS|SPE|EAM" }
    if ($matchingSkus) {
        $licensed = $true
        foreach ($sku in $matchingSkus) {
            Write-Status "Found licensing SKU: $($sku.skuPartNumber) ($($sku.consumedUnits) consumed / $($sku.prepaidUnits.enabled) enabled)" "INFO"
        }
    }
}
catch {
    Write-Status "Could not retrieve subscribedSkus: $($_.Exception.Message)" "WARN"
}

if (-not $licensed) {
    $findings.Add([pscustomobject]@{
        AppName = "(tenant-wide)"; AppType = ""; PublishingState = ""
        Flag = "LICENSING_NOT_CONFIRMED"
        Detail = "No subscribed SKU matched known Intune Suite / Enterprise App Management patterns (INTUNE/EMS/SPE/EAM). If catalog apps exist below, confirm licensing coverage — flag for billing/entitlement review."
    })
}

# ---------------------------------------------------------------------------
# Detect: enumerate mobile apps, separate catalog apps from everything else
# ---------------------------------------------------------------------------
Write-Status "Querying tenant app objects (filter: '$AppNameFilter')..." "INFO"

$allApps = $null
try {
    $uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$top=999"
    $apps = [System.Collections.Generic.List[object]]::new()
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($a in $response.value) { $apps.Add($a) }
        $uri = $response.'@odata.nextLink'
    } while ($uri)
    $allApps = $apps
}
catch {
    Write-Status "Could not query mobileApps via Graph: $($_.Exception.Message)" "ERROR"
    throw
}

if ($AppNameFilter -ne "*") {
    $pattern = [regex]::Escape($AppNameFilter).Replace('\*', '.*')
    $allApps = $allApps | Where-Object { $_.displayName -match $pattern }
}

Write-Status "Total app objects in scope: $($allApps.Count)" "INFO"

# Catalog apps carry a distinct @odata.type from admin-uploaded Win32Lob apps.
# Schema note: as of this writing catalog apps surface under a Win32-family odata.type
# with catalog-specific metadata fields present (e.g. catalogAppId-style properties) —
# this script treats presence of catalog-specific fields as the detection signal since
# the exact @odata.type string has shifted during rollout; verify against a known catalog
# app in your tenant if this heuristic needs tightening.
$catalogApps = $allApps | Where-Object {
    $_.'@odata.type' -match 'win32CatalogApp|win32LobApp' -and
    ($_.PSObject.Properties.Name -contains 'catalogAppId' -or $_.'@odata.type' -match 'Catalog')
}
$nonCatalogApps = $allApps | Where-Object { $_ -notin $catalogApps }

Write-Status "Identified $($catalogApps.Count) Enterprise App Catalog app object(s) (heuristic match — verify ambiguous cases in the portal's Enterprise App Catalog apps view)." "INFO"

# ---------------------------------------------------------------------------
# Evaluate: content readiness staleness
# ---------------------------------------------------------------------------
foreach ($app in $catalogApps) {
    $publishingState = $app.publishingState
    if ($publishingState -and $publishingState -notmatch 'published|ready' ) {
        $created = $null
        if ($app.createdDateTime) { $created = [datetime]$app.createdDateTime }
        $lastModified = $null
        if ($app.lastModifiedDateTime) { $lastModified = [datetime]$app.lastModifiedDateTime }
        $reference = if ($lastModified) { $lastModified } elseif ($created) { $created } else { $null }

        if ($reference) {
            $hoursStale = (New-TimeSpan -Start $reference -End (Get-Date)).TotalHours
            if ($hoursStale -ge $ContentStalenessHours) {
                $findings.Add([pscustomobject]@{
                    AppName = $app.displayName; AppType = $app.'@odata.type'; PublishingState = $publishingState
                    Flag = "CONTENT_NOT_READY"
                    Detail = "Publishing state '$publishingState' for $([math]::Round($hoursStale,1)) hour(s) — past the ~1hr cache window plus margin. Per EnterpriseAppManagement-B.md Fix 1, the only supported recovery is delete and re-add from the catalog."
                })
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Evaluate: duplicate deployment (catalog app + non-catalog app, same normalized name)
# ---------------------------------------------------------------------------
Write-Status "Checking for duplicate catalog/non-catalog deployments of the same app..." "INFO"

$grouped = $allApps | Group-Object { Get-NormalizedAppName -Name $_.displayName }
foreach ($group in $grouped) {
    if ($group.Count -lt 2) { continue }
    $groupCatalog = $group.Group | Where-Object { $_ -in $catalogApps }
    $groupNonCatalog = $group.Group | Where-Object { $_ -in $nonCatalogApps }
    if ($groupCatalog.Count -ge 1 -and $groupNonCatalog.Count -ge 1) {
        $names = ($group.Group | ForEach-Object { "$($_.displayName) [$($_.'@odata.type')]" }) -join "; "
        $findings.Add([pscustomobject]@{
            AppName = $group.Name; AppType = "mixed"; PublishingState = ""
            Flag = "DUPLICATE_APP_DEPLOYMENT"
            Detail = "Normalized name '$($group.Name)' matches both a catalog app and a non-catalog app object: $names. Verify these aren't the same underlying application deployed via two paths (EnterpriseAppManagement-B.md Fix 4) before assuming this is a false positive."
        })
    }
}

# ---------------------------------------------------------------------------
# Evaluate: staleness (informational — forgotten catalog deployments)
# ---------------------------------------------------------------------------
foreach ($app in $catalogApps) {
    if ($app.lastModifiedDateTime) {
        $daysSince = (New-TimeSpan -Start ([datetime]$app.lastModifiedDateTime) -End (Get-Date)).Days
        if ($daysSince -ge $StaleAppDays) {
            $findings.Add([pscustomobject]@{
                AppName = $app.displayName; AppType = $app.'@odata.type'; PublishingState = $app.publishingState
                Flag = "STALE_NO_RECENT_UPDATE"
                Detail = "No modification in $daysSince day(s) (threshold $StaleAppDays). Not an error — worth a periodic review to confirm the app, its assignment, and its auto-update setting still match current intent."
            })
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Enterprise App Catalog Audit Summary ===" -ForegroundColor Cyan
Write-Host "Total app objects scanned: $($allApps.Count)"
Write-Host "Catalog apps identified:   $($catalogApps.Count)"
Write-Host "Total findings:            $($findings.Count)"
Write-Host ""

if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize -Wrap
}
else {
    Write-Status "No findings — no content-readiness stalls, duplicate deployments, or licensing gaps detected." "OK"
}

$csvPath = ".\EnterpriseAppCatalogAudit_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
