<#
.SYNOPSIS
    Audits SharePoint agent governance posture: Knowledge Agent tenant scope, per-site
    Restricted Content Discovery (RCD) agent-suppression exposure, and licensing/metering
    readiness for non-Copilot-licensed users.

.DESCRIPTION
    Automates the Validation Steps and Symptom -> Cause Map checks from Agents-A.md so an
    admin can see the full agent configuration picture in one pass instead of checking
    tenant settings, per-site RCD state, and licensing separately for each ticket.

    Covers:
    - Tenant-wide KnowledgeAgentScope and KnowledgeAgentExcludedSiteIds, with an
      EXCLUSION_LIST_STALE flag when the exclusion list is non-empty but hasn't been
      cross-checked against currently active sites (a common drift point per Agents-A.md
      Playbook 3 -- new sites are never auto-excluded, so an intended allow-list erodes
      silently over time)
    - Per-site RCD (RestrictContentOrgWideSearch) state across the tenant (or a supplied
      site list), with an AGENTS_SUPPRESSED flag on any site where RCD is enabled -- this
      is the single most common "agents disappeared" root cause and is easy to miss because
      RCD's name suggests a search-only control
    - Legacy free-promo opt-in status (Get-SPOCopilotPromoOptInStatus) reported alongside a
      reminder that it is a SEPARATE mechanism from pay-as-you-go metered billing, which
      cannot be checked via SharePoint PowerShell and must be confirmed in the Microsoft 365
      admin center billing page
    - Tenant Copilot licence assignment summary (via Microsoft Graph, if connected) so a
      reviewer can see at a glance how many users have a licensed path to agent creation/use
      versus how many would depend on pay-as-you-go billing

    Does NOT cover:
    - Restricted Access Control (RAC), Site Lifecycle Management, or Data Access Governance --
      see Get-SPAdvancedManagementAudit.ps1 in this same folder
    - Per-agent usage/sharing data from the Copilot Control System (not exposed via SharePoint
      or Graph PowerShell as of this writing; requires the Microsoft 365 admin center UI)
    - Custom agent source-count validation (source lists are not enumerable via PowerShell;
      the 20-item cap is enforced client-side at creation time)

.PARAMETER SiteUrls
    One or more specific site URLs to check RCD state for. If omitted, scans all sites
    (up to -MaxSites) via Get-SPOSite.

.PARAMETER MaxSites
    Safety cap on how many tenant sites to enumerate when -SiteUrls is not supplied.
    Default: 500. Increase for large tenants; a full unscoped scan can be slow.

.PARAMETER SkipGraphLicenseCheck
    Switch. If set, skips the Microsoft Graph Copilot licence summary (useful if only
    connected to SharePoint Online and not Graph).

.PARAMETER OutputPath
    Path to the folder where CSV files will be exported. Default: current directory.

.EXAMPLE
    .\Get-SharePointAgentsAudit.ps1 -OutputPath C:\Temp\AgentsAudit

.EXAMPLE
    .\Get-SharePointAgentsAudit.ps1 -SiteUrls "https://contoso.sharepoint.com/sites/HR" -SkipGraphLicenseCheck

.NOTES
    Requires:
    - Microsoft.Online.SharePoint.PowerShell module (Connect-SPOService), SharePoint
      Administrator role
    - Optionally: Microsoft.Graph.Users module + Organization.Read.All/User.Read.All scopes
      for the Copilot licence summary (Connect-MgGraph)

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to tenant or site configuration.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SiteUrls,

    [Parameter()]
    [int]$MaxSites = 500,

    [Parameter()]
    [switch]$SkipGraphLicenseCheck,

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
    Write-Status "Microsoft.Online.SharePoint.PowerShell module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser" "ERROR"
    return
}

try {
    $null = Get-SPOTenant -ErrorAction Stop
}
catch {
    Write-Status "Not connected to SharePoint Online (or insufficient role). Run Connect-SPOService first." "ERROR"
    Write-Status "  Connect-SPOService -Url https://<tenant>-admin.sharepoint.com" "ERROR"
    return
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Status "Starting SharePoint Agents audit..." "INFO"

# ---------------------------------------------------------------------------
# Section 1: Tenant-wide Knowledge Agent scope
# ---------------------------------------------------------------------------

Write-Status "Checking tenant-wide Knowledge Agent scope..." "INFO"

$tenantSettings = Get-SPOTenant | Select-Object KnowledgeAgentScope, KnowledgeAgentExcludedSiteIds, `
    DelegateRestrictedContentDiscoverabilityManagement

$excludedIdList = @()
if ($tenantSettings.KnowledgeAgentExcludedSiteIds) {
    $excludedIdList = $tenantSettings.KnowledgeAgentExcludedSiteIds -split "," | Where-Object { $_ }
}

$knowledgeAgentSummary = [PSCustomObject]@{
    KnowledgeAgentScope           = $tenantSettings.KnowledgeAgentScope
    ExcludedSiteCount             = $excludedIdList.Count
    RCDDelegatedToSiteAdmins      = $tenantSettings.DelegateRestrictedContentDiscoverabilityManagement
    Flag                          = if ($tenantSettings.KnowledgeAgentScope -eq "ExcludeSelectedSites" -and $excludedIdList.Count -gt 0) {
                                        "EXCLUSION_LIST_PRESENT — verify against current site inventory; new sites are never auto-excluded"
                                    } elseif ($tenantSettings.KnowledgeAgentScope -eq "NoSites") {
                                        "KNOWLEDGE_AGENT_DISABLED_TENANT_WIDE"
                                    } else {
                                        "OK"
                                    }
}

switch ($knowledgeAgentSummary.Flag) {
    "OK"        { Write-Status "Knowledge Agent scope: $($tenantSettings.KnowledgeAgentScope)" "OK" }
    default     { Write-Status "Knowledge Agent scope: $($tenantSettings.KnowledgeAgentScope) -- $($knowledgeAgentSummary.Flag)" "WARN" }
}

# ---------------------------------------------------------------------------
# Section 2: Per-site RCD / agent-suppression scan
# ---------------------------------------------------------------------------

Write-Status "Scanning site-level Restricted Content Discovery (agent-suppression) state..." "INFO"

if ($SiteUrls -and $SiteUrls.Count -gt 0) {
    $sites = foreach ($url in $SiteUrls) {
        try { Get-SPOSite -Identity $url -ErrorAction Stop }
        catch { Write-Status "Could not resolve site: $url -- $($_.Exception.Message)" "WARN" }
    }
}
else {
    $sites = Get-SPOSite -Limit $MaxSites
    if ($sites.Count -ge $MaxSites) {
        Write-Status "Site scan capped at -MaxSites ($MaxSites). Increase the parameter for a full tenant scan." "WARN"
    }
}

$siteResults = foreach ($site in $sites) {
    $rcdEnabled = $false
    try { $rcdEnabled = [bool]$site.RestrictContentOrgWideSearch } catch { }

    [PSCustomObject]@{
        Url                = $site.Url
        Title              = $site.Title
        Template           = $site.Template
        RCDEnabled         = $rcdEnabled
        AgentsAvailable    = -not $rcdEnabled
        KnowledgeAgentExcluded = ($excludedIdList -contains $site.SiteId.ToString())
        Flag               = if ($rcdEnabled) { "AGENTS_SUPPRESSED — RCD disables ready-made agent, custom agent creation, and use as a source elsewhere" } else { "OK" }
    }
}

$suppressedCount = ($siteResults | Where-Object { $_.RCDEnabled }).Count
if ($suppressedCount -gt 0) {
    Write-Status "$suppressedCount of $($siteResults.Count) scanned sites have RCD enabled (agents suppressed)." "WARN"
}
else {
    Write-Status "No scanned sites have RCD-suppressed agents." "OK"
}

# ---------------------------------------------------------------------------
# Section 3: Legacy promo opt-in status
# ---------------------------------------------------------------------------

Write-Status "Checking legacy agent promo opt-in status..." "INFO"

$promoStatus = $null
try {
    $promoStatus = Get-SPOCopilotPromoOptInStatus
}
catch {
    Write-Status "Get-SPOCopilotPromoOptInStatus not available or errored: $($_.Exception.Message)" "WARN"
}

$promoSummary = [PSCustomObject]@{
    PromoOptInStatus = if ($promoStatus) { $promoStatus } else { "UNAVAILABLE" }
    Note             = "This reflects the LEGACY free-promo mechanism only (ended Jun 30 2025). Pay-as-you-go metered billing is a SEPARATE setting, checked only in the Microsoft 365 admin center Billing page — not queryable via SharePoint PowerShell."
}

# ---------------------------------------------------------------------------
# Section 4: Optional Copilot licence summary via Graph
# ---------------------------------------------------------------------------

$licenseSummary = $null
if (-not $SkipGraphLicenseCheck) {
    Write-Status "Checking tenant Copilot licence assignment via Microsoft Graph..." "INFO"
    try {
        $skus = Get-MgSubscribedSku -ErrorAction Stop
        $copilotSkus = $skus | Where-Object { $_.SkuPartNumber -like "*COPILOT*" }

        if ($copilotSkus) {
            $licenseSummary = $copilotSkus | ForEach-Object {
                [PSCustomObject]@{
                    SkuPartNumber  = $_.SkuPartNumber
                    ConsumedUnits  = $_.ConsumedUnits
                    PrepaidUnits   = $_.PrepaidUnits.Enabled
                    RemainingUnits = $_.PrepaidUnits.Enabled - $_.ConsumedUnits
                }
            }
            Write-Status "Found $($copilotSkus.Count) Copilot SKU(s) in tenant." "OK"
        }
        else {
            Write-Status "No Copilot SKU found in tenant. Non-Copilot users depend entirely on pay-as-you-go billing for agent access." "WARN"
        }
    }
    catch {
        Write-Status "Microsoft Graph not connected or Get-MgSubscribedSku unavailable. Skipping licence summary. Connect with: Connect-MgGraph -Scopes 'Organization.Read.All'" "WARN"
    }
}
else {
    Write-Status "Skipping Graph licence check (-SkipGraphLicenseCheck set)." "INFO"
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$knowledgeAgentSummary | Export-Csv -Path (Join-Path $OutputPath "AgentsAudit-KnowledgeAgentScope-$timestamp.csv") -NoTypeInformation
$siteResults | Export-Csv -Path (Join-Path $OutputPath "AgentsAudit-SiteRCDState-$timestamp.csv") -NoTypeInformation
$promoSummary | Export-Csv -Path (Join-Path $OutputPath "AgentsAudit-PromoStatus-$timestamp.csv") -NoTypeInformation
if ($licenseSummary) {
    $licenseSummary | Export-Csv -Path (Join-Path $OutputPath "AgentsAudit-CopilotLicenses-$timestamp.csv") -NoTypeInformation
}

Write-Status "Audit complete. CSV files exported to $OutputPath" "OK"

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------

Write-Host "`n=== SharePoint Agents Audit Summary ===" -ForegroundColor Cyan
Write-Host "Knowledge Agent scope:        $($tenantSettings.KnowledgeAgentScope)"
Write-Host "Sites scanned:                $($siteResults.Count)"
Write-Host "Sites with agents suppressed: $suppressedCount"
Write-Host "Legacy promo opt-in status:   $($promoSummary.PromoOptInStatus)"
if ($licenseSummary) {
    Write-Host "Copilot SKUs in tenant:       $($licenseSummary.Count)"
}
Write-Host "========================================`n" -ForegroundColor Cyan
