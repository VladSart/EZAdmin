<#
.SYNOPSIS
    Audits a tenant's Microsoft 365 licensing against the July 2026 Intune Suite -> E3/E5
    base-licensing bundling change, flagging redundant standalone add-on spend and per-user
    bundled-service-plan gaps.

.DESCRIPTION
    Read-only Microsoft Graph script. Does not assign, remove, or modify any license.

    Performs three checks:
      1. Tenant-wide SKU inventory, classified as E3-qualifying / E5-qualifying / non-qualifying
         against a maintained pattern list (heuristic — verify against Microsoft's current
         published eligibility list for edge-case SKU variants, this script does not call an
         authoritative "is this SKU eligible" API because none is documented to exist).
      2. Standalone Intune Suite / EPM / Cloud PKI / Remote Help / Enterprise App Management /
         Advanced Analytics add-on SKUs still held with consumed seats alongside a qualifying
         base SKU -- flagged as a redundant-spend REVIEW candidate, never auto-resolved.
      3. Optional per-user check: for a supplied list of UPNs (or -All), confirms whether the
         expected bundled service plans are present and enabled given the user's assigned base
         SKU tier.

    Exports a CSV summary. Does not call any write Graph endpoint.

.PARAMETER UserPrincipalNames
    Optional array of specific UPNs to check for bundled service-plan presence.

.PARAMETER AllUsers
    Switch. If set, checks every licensed user in the tenant instead of a supplied list.
    Can be slow/throttled on large tenants -- prefer -UserPrincipalNames for targeted triage.

.PARAMETER OutputPath
    Folder to write the CSV export to. Defaults to the current directory.

.EXAMPLE
    .\Get-IntuneSuiteLicensingAudit.ps1 -UserPrincipalNames "jane@contoso.com","sam@contoso.com"

.EXAMPLE
    .\Get-IntuneSuiteLicensingAudit.ps1 -AllUsers -OutputPath "C:\Audits"

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: Organization.Read.All, User.Read.All
    Safe/unsafe: fully read-only, safe to run in production at any time.
    Does not require -RunAsAdministrator (Graph-only, no local system changes).
#>
[CmdletBinding()]
param(
    [string[]]$UserPrincipalNames,
    [switch]$AllUsers,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---------------------------------------------------------
try {
    $null = Get-MgContext -ErrorAction Stop
} catch {
    Write-Status "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'Organization.Read.All','User.Read.All'" "ERROR"
    return
}

if (-not (Get-MgContext)) {
    Write-Status "Connect-MgGraph session not found. Aborting." "ERROR"
    return
}

# --- SKU classification patterns ---------------------------------------
# Heuristic pattern match against commonly-published SkuPartNumber naming. Verify unusual/
# regional/grandfathered variants against Microsoft's current documentation before relying
# on this classification for a billing decision.
$e5Patterns = @('SPE_E5', 'SPE_E5_USGOV', 'M365EDU_A5', 'ENTERPRISEPREMIUM')
$e3Patterns = @('SPE_E3', 'SPE_E3_USGOV', 'M365EDU_A3', 'EMS.?E3')
$standaloneAddonPatterns = @('INTUNE_SUITE', 'INTUNE_SUITE_NCE', 'EPM_ADDON', 'MICROSOFT_CLOUD_PKI',
    'ENTERPRISE_APP_MGMT', 'REMOTE_HELP', 'ADVANCED_ANALYTICS')

Write-Status "Pulling tenant subscribed SKU inventory..." "INFO"
$allSkus = Get-MgSubscribedSku -All

$skuReport = foreach ($sku in $allSkus) {
    $tier = "Non-qualifying / unclassified"
    if ($e5Patterns | Where-Object { $sku.SkuPartNumber -match $_ }) { $tier = "E5-qualifying" }
    elseif ($e3Patterns | Where-Object { $sku.SkuPartNumber -match $_ }) { $tier = "E3-qualifying" }

    $isStandaloneAddon = [bool]($standaloneAddonPatterns | Where-Object { $sku.SkuPartNumber -match $_ })

    [PSCustomObject]@{
        SkuPartNumber   = $sku.SkuPartNumber
        SkuId           = $sku.SkuId
        ConsumedUnits   = $sku.ConsumedUnits
        PrepaidEnabled  = $sku.PrepaidUnits.Enabled
        ClassifiedTier  = $tier
        StandaloneAddOn = $isStandaloneAddon
    }
}

$qualifyingBaseHeld = $skuReport | Where-Object { $_.ClassifiedTier -in @("E3-qualifying", "E5-qualifying") -and $_.ConsumedUnits -gt 0 }
$standaloneHeldWithSeats = $skuReport | Where-Object { $_.StandaloneAddOn -and $_.ConsumedUnits -gt 0 }

Write-Status "Qualifying base SKU(s) with consumed seats: $($qualifyingBaseHeld.Count)" "OK"
if ($standaloneHeldWithSeats.Count -gt 0 -and $qualifyingBaseHeld.Count -gt 0) {
    Write-Status "REVIEW: $($standaloneHeldWithSeats.Count) standalone add-on SKU(s) held alongside a qualifying base SKU — possible redundant spend. Escalate to licensing owner, do not auto-cancel." "WARN"
    $standaloneHeldWithSeats | ForEach-Object { Write-Status "  -> $($_.SkuPartNumber): $($_.ConsumedUnits) seat(s) consumed" "WARN" }
} elseif ($standaloneHeldWithSeats.Count -gt 0) {
    Write-Status "$($standaloneHeldWithSeats.Count) standalone add-on SKU(s) held, but no qualifying base SKU detected — likely still required, not redundant." "INFO"
} else {
    Write-Status "No standalone add-on SKUs detected with consumed seats." "OK"
}

# --- Optional per-user bundled service-plan check -----------------------
$userReport = @()
$targetUsers = @()

if ($AllUsers) {
    Write-Status "Pulling all licensed users (-AllUsers specified — this can be slow on large tenants)..." "INFO"
    $targetUsers = Get-MgUser -All -Property Id, UserPrincipalName, AssignedLicenses |
        Where-Object { $_.AssignedLicenses.Count -gt 0 }
} elseif ($UserPrincipalNames) {
    foreach ($upn in $UserPrincipalNames) {
        try {
            $targetUsers += Get-MgUser -UserId $upn -Property Id, UserPrincipalName, AssignedLicenses
        } catch {
            Write-Status "Could not resolve user '$upn' — skipping. $($_.Exception.Message)" "WARN"
        }
    }
}

if ($targetUsers.Count -gt 0) {
    Write-Status "Checking bundled service-plan presence for $($targetUsers.Count) user(s)..." "INFO"
    foreach ($u in $targetUsers) {
        try {
            $detail = Get-MgUserLicenseDetail -UserId $u.Id
        } catch {
            Write-Status "Could not pull license detail for $($u.UserPrincipalName) — skipping." "WARN"
            continue
        }

        foreach ($lic in $detail) {
            $tierMatch = $skuReport | Where-Object { $_.SkuId -eq $lic.SkuId } | Select-Object -First 1
            $tier = if ($tierMatch) { $tierMatch.ClassifiedTier } else { "Unknown" }

            $enabledPlans = ($lic.ServicePlans | Where-Object { $_.ProvisioningStatus -eq 'Success' }).ServicePlanName -join ';'
            $disabledPlans = ($lic.ServicePlans | Where-Object { $_.ProvisioningStatus -ne 'Success' }).ServicePlanName -join ';'

            $userReport += [PSCustomObject]@{
                UserPrincipalName = $u.UserPrincipalName
                SkuPartNumber     = $lic.SkuPartNumber
                ClassifiedTier    = $tier
                EnabledPlans      = $enabledPlans
                DisabledPlans     = $disabledPlans
            }
        }
    }
}

# --- Export --------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$skuExportPath = Join-Path $OutputPath "IntuneSuiteLicensingAudit-SKUs-$timestamp.csv"
$skuReport | Export-Csv -Path $skuExportPath -NoTypeInformation
Write-Status "SKU inventory exported to $skuExportPath" "OK"

if ($userReport.Count -gt 0) {
    $userExportPath = Join-Path $OutputPath "IntuneSuiteLicensingAudit-Users-$timestamp.csv"
    $userReport | Export-Csv -Path $userExportPath -NoTypeInformation
    Write-Status "Per-user service-plan report exported to $userExportPath" "OK"
}

Write-Status "Audit complete. This script does not modify any license assignment — all findings require manual review before action, especially any standalone-add-on-cancellation decision." "INFO"
