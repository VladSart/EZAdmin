<#
.SYNOPSIS
    Audits Azure Front Door Premium profiles for Private Link origin configuration health.

.DESCRIPTION
    Read-only, tenant/subscription-wide sweep across every Azure Front Door CDN profile.
    For each profile it inventories every origin group and origin, and for any origin using
    a SharedPrivateLinkResource (i.e. Private Link-enabled) it flags:
      - Connection state (Pending / Approved / Rejected / Timeout / Disconnected)
      - Tier mismatch (a Private Link config found on a non-Premium profile, which should be
        impossible via normal tooling but is worth flagging if seen — e.g. post tier-downgrade)
      - Origin groups mixing private and public origins (unsupported platform state)
      - Multiple origins sharing the same resource ID + Group ID + region (same underlying
        Private Endpoint) that use DIFFERENT HTTP/HTTPS ports — the documented routing-issue trap
      - Private Link region chosen vs. a best-effort AZ-region reference list, flagging
        potentially non-ideal region choices for manual latency review

    What this script does NOT do:
      - It does not query or approve Private Endpoint connections on the ORIGIN resource side
        (that requires Contributor rights on the origin's own resource group, which the Front
        Door-focused identity running this script may not have — see the console output for a
        reminder to check the origin side manually for any origin flagged Pending).
      - It does not measure live request volume against the 7200 RPS/region/profile cap — that
        requires Log Analytics/metrics access scoped separately; see FrontDoorPrivateLink-A.md's
        Evidence Pack section for a metrics-based follow-up.
      - The supported-region reference list is maintained by hand from published documentation
        and may lag newly added regions; treat a REGION-NOT-IN-REFERENCE-LIST flag as a prompt
        to check current docs, not a definitive failure.

.PARAMETER SubscriptionId
    Optional. If provided, scopes the audit to a single subscription. If omitted, iterates every
    subscription the authenticated context can see.

.PARAMETER OutputPath
    Folder to write the CSV report to. Defaults to the current directory.

.EXAMPLE
    .\Get-FrontDoorPrivateLinkAudit.ps1

    Audits every Front Door profile across every accessible subscription.

.EXAMPLE
    .\Get-FrontDoorPrivateLinkAudit.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -OutputPath "C:\Reports"

.NOTES
    Requires: Az.Accounts, Az.Cdn modules, and Reader (minimum) on Front Door profiles.
    Read-only — makes no configuration changes. Safe to run in production at any time.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# Best-effort reference list of Front Door Private Link-supported (AZ-enabled) regions.
# Maintained by hand from published documentation — see .DESCRIPTION caveat above.
$SupportedPLRegions = @(
    "brazilsouth", "canadacentral", "centralus", "eastus", "eastus2", "southcentralus", "westus2", "westus3",
    "francecentral", "germanywestcentral", "northeurope", "norwayeast", "uksouth", "westeurope", "swedencentral",
    "southafricanorth", "uaenorth",
    "australiaeast", "centralindia", "japaneast", "koreacentral", "eastasia", "southeastasia",
    "chinaeast3", "chinanorth3",
    "usgovarizona", "usgovtexas", "usgovvirginia", "usnateast", "usnatwest", "usseceast", "ussecwest"
)

#region Preflight
Write-Status "Checking Az PowerShell modules..."
foreach ($mod in @("Az.Accounts", "Az.Cdn")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        return
    }
}

$context = Get-AzContext
if (-not $context) {
    Write-Status "No active Az context. Run Connect-AzAccount first." "ERROR"
    return
}
Write-Status "Authenticated as $($context.Account.Id)" "OK"
#endregion

#region Detect
$subs = if ($SubscriptionId) {
    Get-AzSubscription -SubscriptionId $SubscriptionId
} else {
    Get-AzSubscription
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($sub in $subs) {
    Write-Status "Scanning subscription: $($sub.Name) ($($sub.Id))"
    try {
        Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
        Write-Status "Could not set context for $($sub.Id): $($_.Exception.Message)" "WARN"
        continue
    }

    $profiles = $null
    try {
        $profiles = Get-AzFrontDoorCdnProfile -ErrorAction Stop
    } catch {
        Write-Status "  No Front Door CDN profiles accessible in this subscription, or an error occurred: $($_.Exception.Message)" "WARN"
        continue
    }

    if (-not $profiles -or $profiles.Count -eq 0) {
        Write-Status "  No Front Door profiles found." "INFO"
        continue
    }

    foreach ($fdProfile in $profiles) {
        $rgName = ($fdProfile.Id -split '/resourceGroups/')[1].Split('/')[0]
        Write-Status "  Profile: $($fdProfile.Name)  [SKU: $($fdProfile.SkuName)]"

        $originGroups = $null
        try {
            $originGroups = Get-AzFrontDoorCdnOriginGroup -ResourceGroupName $rgName -ProfileName $fdProfile.Name -ErrorAction Stop
        } catch {
            Write-Status "    Could not enumerate origin groups: $($_.Exception.Message)" "WARN"
            continue
        }

        foreach ($og in $originGroups) {
            $origins = $null
            try {
                $origins = Get-AzFrontDoorCdnOrigin -ResourceGroupName $rgName -ProfileName $fdProfile.Name -OriginGroupName $og.Name -ErrorAction Stop
            } catch {
                Write-Status "    Could not enumerate origins for group $($og.Name): $($_.Exception.Message)" "WARN"
                continue
            }

            if (-not $origins -or $origins.Count -eq 0) { continue }

            $privateFlags = $origins | ForEach-Object { $null -ne $_.SharedPrivateLinkResource }
            $isMixedGroup = ($privateFlags | Select-Object -Unique).Count -gt 1

            # Group private origins by shared-PE tuple to detect port conflicts
            $peGroups = $origins | Where-Object { $_.SharedPrivateLinkResource } | Group-Object {
                "$($_.SharedPrivateLinkResource.PrivateLink)|$($_.SharedPrivateLinkResource.GroupId)|$($_.SharedPrivateLinkResource.PrivateLinkLocation)"
            }

            foreach ($o in $origins) {
                $pl = $o.SharedPrivateLinkResource
                $isPrivate = $null -ne $pl

                $portConflict = $false
                if ($isPrivate) {
                    $tuple = "$($pl.PrivateLink)|$($pl.GroupId)|$($pl.PrivateLinkLocation)"
                    $sharedGroup = $peGroups | Where-Object { $_.Name -eq $tuple }
                    if ($sharedGroup -and $sharedGroup.Count -gt 1) {
                        $portSet = $sharedGroup.Group | ForEach-Object { "$($_.HttpPort)/$($_.HttpsPort)" } | Select-Object -Unique
                        $portConflict = $portSet.Count -gt 1
                    }
                }

                $tierMismatch = $isPrivate -and ($fdProfile.SkuName -notlike "Premium*")

                $regionFlag = $null
                if ($isPrivate -and $pl.PrivateLinkLocation) {
                    $normalizedRegion = ($pl.PrivateLinkLocation -replace '\s', '').ToLower()
                    if ($normalizedRegion -notin $SupportedPLRegions) {
                        $regionFlag = "REGION-NOT-IN-REFERENCE-LIST (verify against current docs)"
                    }
                }

                $statusFlag = if ($isPrivate) {
                    switch ($pl.Status) {
                        "Approved" { "OK" }
                        "Pending" { "ACTION-NEEDED: approve on origin side" }
                        "Rejected" { "DEAD: recreate the origin's Private Link config" }
                        "Timeout" { "DEAD: recreate the origin's Private Link config" }
                        "Disconnected" { "DEAD: recreate the origin's Private Link config" }
                        default { "UNKNOWN: $($pl.Status)" }
                    }
                } else { "N/A (public origin)" }

                $results.Add([pscustomobject]@{
                    Subscription        = $sub.Name
                    ResourceGroup       = $rgName
                    ProfileName         = $fdProfile.Name
                    ProfileSku          = $fdProfile.SkuName
                    OriginGroup         = $og.Name
                    OriginName          = $o.Name
                    PrivateLinkEnabled  = $isPrivate
                    ConnectionStatus    = if ($isPrivate) { $pl.Status } else { $null }
                    StatusFlag          = $statusFlag
                    PLResourceId        = if ($isPrivate) { $pl.PrivateLink } else { $null }
                    PLGroupId           = if ($isPrivate) { $pl.GroupId } else { $null }
                    PLRegion            = if ($isPrivate) { $pl.PrivateLinkLocation } else { $null }
                    RegionFlag          = $regionFlag
                    HttpPort            = $o.HttpPort
                    HttpsPort           = $o.HttpsPort
                    MixedOriginGroup    = $isMixedGroup
                    SharedPEPortConflict = $portConflict
                    TierMismatchFlag    = $tierMismatch
                })
            }
        }
    }
}
#endregion

#region Report
if ($results.Count -eq 0) {
    Write-Status "No origins found across scanned profiles." "WARN"
    return
}

$privateOrigins = $results | Where-Object PrivateLinkEnabled
Write-Status "----- Summary -----"
Write-Status "Total origins scanned: $($results.Count)"
Write-Status "Private Link-enabled origins: $($privateOrigins.Count)"

$pending = $privateOrigins | Where-Object { $_.ConnectionStatus -eq "Pending" }
if ($pending.Count -gt 0) {
    Write-Status "$($pending.Count) origin(s) with Pending connections — needs approval on the ORIGIN resource side:" "WARN"
    $pending | ForEach-Object { Write-Status "  $($_.ProfileName) / $($_.OriginGroup) / $($_.OriginName)" "WARN" }
}

$dead = $privateOrigins | Where-Object { $_.StatusFlag -like "DEAD*" }
if ($dead.Count -gt 0) {
    Write-Status "$($dead.Count) origin(s) with a dead connection (Rejected/Timeout/Disconnected) — must be recreated:" "ERROR"
    $dead | ForEach-Object { Write-Status "  $($_.ProfileName) / $($_.OriginGroup) / $($_.OriginName)" "ERROR" }
}

$mixed = $results | Where-Object MixedOriginGroup | Select-Object ProfileName, OriginGroup -Unique
if ($mixed.Count -gt 0) {
    Write-Status "$($mixed.Count) origin group(s) mixing public and private origins (unsupported state):" "ERROR"
    $mixed | ForEach-Object { Write-Status "  $($_.ProfileName) / $($_.OriginGroup)" "ERROR" }
}

$portConflicts = $results | Where-Object SharedPEPortConflict
if ($portConflicts.Count -gt 0) {
    Write-Status "$($portConflicts.Count) origin(s) on a shared Private Endpoint with mismatched ports (routing-issue risk):" "WARN"
    $portConflicts | ForEach-Object { Write-Status "  $($_.ProfileName) / $($_.OriginGroup) / $($_.OriginName)" "WARN" }
}

$tierMismatch = $results | Where-Object TierMismatchFlag
if ($tierMismatch.Count -gt 0) {
    Write-Status "$($tierMismatch.Count) origin(s) with Private Link config found on a non-Premium profile (unexpected — verify manually):" "ERROR"
}

$regionFlags = $results | Where-Object { $_.RegionFlag }
if ($regionFlags.Count -gt 0) {
    Write-Status "$($regionFlags.Count) origin(s) using a Private Link region not in this script's reference list — verify against current docs:" "WARN"
}

if ($pending.Count -eq 0 -and $dead.Count -eq 0 -and $mixed.Count -eq 0 -and $portConflicts.Count -eq 0 -and $tierMismatch.Count -eq 0) {
    Write-Status "No Private Link origin issues detected." "OK"
}

Write-Status "Reminder: this script cannot see or approve Private Endpoint connections on the ORIGIN side — for any origin flagged Pending, check Get-AzPrivateEndpointConnection against the origin's own resource group." "INFO"

$csvPath = Join-Path $OutputPath "FrontDoorPrivateLinkAudit-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Full report exported to $csvPath" "OK"
#endregion
