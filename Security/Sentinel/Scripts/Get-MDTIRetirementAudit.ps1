<#
.SYNOPSIS
    Audits a tenant's readiness for the Microsoft Defender Threat Intelligence (MDTI)
    standalone-product retirement (August 1, 2026) — licensing coverage for the surviving
    Defender-portal research experience, optional Sentinel connector presence, and
    per-user license assignment gaps.

.DESCRIPTION
    Companion script to Security/Sentinel/MDTIRetirement-B.md and -A.md.

    Since the retired standalone MDTI product has no PowerShell/Graph surface of its own
    (it was a separate portal/product, not a Graph-exposed resource), this script does NOT
    attempt to read standalone-MDTI state directly. Instead it audits the things that
    actually determine whether a tenant/user still has full threat-intelligence research
    access after the retirement:

    - Tenant-wide SKU inventory, flagging any SKU that is documented to include the
      post-retirement Intelligence explorer / Intel profiles research experience
      (Microsoft 365 E5 family, an E5 Security add-on, or Microsoft Defender for
      Endpoint Plan 2)
    - Per-user license assignment against that same qualifying-SKU list, for a supplied
      list of users (typically a SOC/security-analyst group) — flags analysts who may
      have LOST research-experience access if their org's only prior path was a now-
      retired standalone MDTI subscription
    - Optional Sentinel data connector check (if -ResourceGroupName/-WorkspaceName are
      supplied) confirming whether a "Defender Threat Intelligence"-kind connector is
      present as an alternate, license-free access path
    - A plain-language summary distinguishing "no qualifying SKU anywhere in the tenant"
      (a licensing/procurement decision) from "qualifying SKU exists but isn't assigned
      to this analyst" (an assignment fix)

    Does NOT cover:
    - Verifying the retired standalone portal's own functionality (nothing to check — it
      is retired with no supported access path as of this writing)
    - Sentinel's own STIX threat-intelligence ingestion health (ThreatIntelIndicators/
      ThreatIntelObjects table freshness) — see Get-SentinelThreatIntelAudit.ps1 instead,
      since that is an entirely separate, unaffected system
    - CSP/Partner Center billing or credit-memo status — that lives in Partner Center,
      outside any tenant-side Graph/PowerShell surface this script can reach
    - Assigning or changing any license — this script is read-only / reporting only

.PARAMETER UserPrincipalNames
    One or more UPNs (typically your SOC/security-analyst group) to check individually
    for a qualifying license assignment. Optional — tenant-wide SKU inventory still runs
    without this.

.PARAMETER ResourceGroupName
    Resource group containing the Sentinel-linked Log Analytics workspace, if you want
    the optional Sentinel connector check included. Requires -WorkspaceName as well.

.PARAMETER WorkspaceName
    Name of the Sentinel-linked Log Analytics workspace. Requires -ResourceGroupName.

.PARAMETER ExportPath
    Path for CSV export. Default: .\MDTIRetirementAudit-<timestamp>.csv

.EXAMPLE
    .\Get-MDTIRetirementAudit.ps1
    Runs the tenant-wide qualifying-SKU inventory only.

.EXAMPLE
    .\Get-MDTIRetirementAudit.ps1 -UserPrincipalNames "alice@contoso.com","bob@contoso.com"
    Also checks specific analysts' individual license assignments against the qualifying-SKU list.

.EXAMPLE
    .\Get-MDTIRetirementAudit.ps1 -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel-prod"
    Also checks for a Sentinel Defender-Threat-Intelligence connector as an alternate access path.

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement modules
    (Connect-MgGraph -Scopes "Organization.Read.All","User.Read.All" first).
    For the optional Sentinel check: Az.SecurityInsights module and an authenticated Az session.
    Read-only. Makes no configuration changes and assigns no licenses.
#>

[CmdletBinding()]
param(
    [string[]]$UserPrincipalNames,
    [string]$ResourceGroupName,
    [string]$WorkspaceName,
    [string]$ExportPath = ".\MDTIRetirementAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# SKU name patterns documented (or strongly implied by Microsoft's licensing guidance) to
# include the post-retirement Defender-portal threat-intelligence research experience.
# NOTE: exact SkuPartNumber strings can vary by region/agreement type — treat a MISS here
# as "verify manually against the current licensing matrix," not as a definitive "not licensed."
$QualifyingSkuPatterns = @(
    "SPE_E5",                      # Microsoft 365 E5 (and variants)
    "SPE_E5_RPA1",
    "EMSPREMIUM",                  # EMS E5 (component of some E5 bundles)
    "ATP_ENTERPRISE",              # Microsoft Defender for Office 365 P2 family naming overlap - verify
    "MDATP",                       # Microsoft Defender for Endpoint P2
    "IDENTITY_THREAT_PROTECTION",  # M365 E5 Security add-on family
    "THREAT_INTELLIGENCE"
)

$results = [System.Collections.Generic.List[object]]::new()

# ── Step 1: Tenant-wide SKU inventory ──────────────────────────────────────────────
Write-Status "Checking tenant SKU inventory for qualifying licenses..." "INFO"
try {
    $allSkus = Get-MgSubscribedSku -ErrorAction Stop
} catch {
    Write-Status "Get-MgSubscribedSku failed — confirm Connect-MgGraph -Scopes 'Organization.Read.All' has run. Error: $($_.Exception.Message)" "ERROR"
    $allSkus = @()
}

$qualifyingSkus = $allSkus | Where-Object {
    $skuName = $_.SkuPartNumber
    ($QualifyingSkuPatterns | Where-Object { $skuName -match $_ }).Count -gt 0
}

if ($qualifyingSkus) {
    Write-Status "Found $($qualifyingSkus.Count) potentially-qualifying SKU(s) in the tenant." "OK"
    foreach ($sku in $qualifyingSkus) {
        Write-Host "    $($sku.SkuPartNumber): $($sku.ConsumedUnits)/$($sku.PrepaidUnits.Enabled) consumed/prepaid"
        $results.Add([PSCustomObject]@{
            CheckType       = "TenantSkuInventory"
            Target          = $sku.SkuPartNumber
            Finding         = "Qualifying SKU present"
            ConsumedUnits   = $sku.ConsumedUnits
            PrepaidUnits    = $sku.PrepaidUnits.Enabled
            Recommendation  = "Confirm this SKU is actually assigned to your security/SOC analysts, not just held at the tenant level"
        })
    }
} else {
    Write-Status "No obviously-qualifying SKU found by name pattern. Verify manually against the current licensing matrix before concluding the tenant lacks research-experience access — Sentinel's free connector is an alternate path not captured by SKU inventory alone." "WARN"
    $results.Add([PSCustomObject]@{
        CheckType      = "TenantSkuInventory"
        Target         = "(tenant-wide)"
        Finding        = "No qualifying SKU matched by name pattern"
        ConsumedUnits  = $null
        PrepaidUnits   = $null
        Recommendation = "Verify manually; check for a Sentinel connector as an alternate free access path"
    })
}

# ── Step 2: Per-user license assignment check (optional) ──────────────────────────
if ($UserPrincipalNames) {
    Write-Status "Checking $($UserPrincipalNames.Count) user(s) for qualifying license assignment..." "INFO"
    foreach ($upn in $UserPrincipalNames) {
        try {
            $licenseDetails = Get-MgUserLicenseDetail -UserId $upn -ErrorAction Stop
            $hasQualifying = $licenseDetails | Where-Object {
                $skuName = $_.SkuPartNumber
                ($QualifyingSkuPatterns | Where-Object { $skuName -match $_ }).Count -gt 0
            }

            if ($hasQualifying) {
                Write-Status "$upn : has a qualifying license ($($hasQualifying.SkuPartNumber -join ', '))" "OK"
                $finding = "Qualifying license assigned"
                $rec = "No action needed"
            } else {
                Write-Status "$upn : NO qualifying license found among assigned SKUs" "WARN"
                $finding = "No qualifying license assigned"
                $rec = "May have lost full research-experience access if this org's only prior path was standalone MDTI - confirm with the user's manager whether an add-on or Sentinel access is needed"
            }

            $results.Add([PSCustomObject]@{
                CheckType      = "UserLicenseAssignment"
                Target         = $upn
                Finding        = $finding
                ConsumedUnits  = $null
                PrepaidUnits   = $null
                Recommendation = $rec
            })
        } catch {
            Write-Status "$upn : lookup failed - $($_.Exception.Message)" "ERROR"
            $results.Add([PSCustomObject]@{
                CheckType      = "UserLicenseAssignment"
                Target         = $upn
                Finding        = "Lookup failed: $($_.Exception.Message)"
                ConsumedUnits  = $null
                PrepaidUnits   = $null
                Recommendation = "Confirm UPN is correct and caller has User.Read.All"
            })
        }
    }
} else {
    Write-Status "No -UserPrincipalNames supplied - skipping per-user assignment check." "INFO"
}

# ── Step 3: Optional Sentinel connector check (alternate, license-free access path) ─
if ($ResourceGroupName -and $WorkspaceName) {
    Write-Status "Checking for a Sentinel Defender-Threat-Intelligence connector in $WorkspaceName..." "INFO"
    try {
        $connectors = Get-AzSentinelDataConnector -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ErrorAction Stop
        $tiConnector = $connectors | Where-Object { $_.Kind -match "ThreatIntelligence|MDTI" }

        if ($tiConnector) {
            Write-Status "Threat-intelligence connector found (Kind: $($tiConnector.Kind)) - this is a free, license-independent access path to Threat Intelligence Insights data." "OK"
            $finding = "TI connector present"
        } else {
            Write-Status "No threat-intelligence-kind connector found in this workspace." "WARN"
            $finding = "No TI connector found"
        }

        $results.Add([PSCustomObject]@{
            CheckType      = "SentinelConnector"
            Target         = "$ResourceGroupName/$WorkspaceName"
            Finding        = $finding
            ConsumedUnits  = $null
            PrepaidUnits   = $null
            Recommendation = if ($tiConnector) { "No action needed" } else { "Consider enabling the connector as a free alternate access path if licensing coverage is otherwise incomplete" }
        })
    } catch {
        Write-Status "Sentinel connector check failed - confirm Az.SecurityInsights is installed and an Az session is authenticated. Error: $($_.Exception.Message)" "ERROR"
    }
} else {
    Write-Status "No -ResourceGroupName/-WorkspaceName supplied - skipping Sentinel connector check." "INFO"
}

# ── Export ──────────────────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full results exported to $ExportPath" "OK"

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Reminder: the retired standalone MDTI product has no direct PowerShell/Graph surface." -ForegroundColor DarkGray
Write-Host "This script audits the LICENSING/CONNECTOR paths that determine post-retirement access," -ForegroundColor DarkGray
Write-Host "not the (nonexistent, retired) standalone product itself." -ForegroundColor DarkGray
$results | Format-Table -AutoSize
