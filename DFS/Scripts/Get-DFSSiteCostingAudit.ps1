<#
.SYNOPSIS
    Audits the AD Sites and Services topology that drives DFS referral ordering — subnet
    coverage, site-link costs, and manual folder-target priority overrides — to catch the
    root causes behind "wrong branch office is being routed to the wrong file server."

.DESCRIPTION
    DFS referral ordering is computed almost entirely from AD topology that DFS itself does
    not own: AD Subnet objects (client IP -> site), AD Site Link costs (site -> site distance),
    and per-folder-target manual ReferralPriorityClass/Rank overrides. A gap or overlap at the
    subnet layer silently produces "random"-looking referral behavior that looks identical to a
    DFS bug but has nothing to do with DFS configuration.

    This script:
      1. Reports every AD subnet-to-site mapping (flags any subnet with no site, a common gap
         when a network team adds a VLAN without notifying identity/AD owners).
      2. Reports every AD site link and its cost.
      3. Reports every folder target's ReferralPriorityClass/Rank for a given namespace folder,
         flagging anything that isn't the default SiteCost/rank-0 (these silently outrank
         topology-based ordering and are the most common "should be working per topology but
         isn't" root cause).
      4. Reports the namespace's referral ordering method fetch is not exposed by DFSN cmdlets
         (must be checked via GUI/dfsutil per DFS-SiteCosting-A.md) — this script notes that
         limitation rather than silently omitting it.

.PARAMETER NamespacePath
    UNC path to the DFS namespace root, e.g. \\contoso.com\Public

.PARAMETER FolderPath
    Optional. A specific namespace folder (e.g. \\contoso.com\Public\Finance) to audit
    ReferralPriorityClass/Rank overrides for. If omitted, only site/subnet/site-link topology
    is audited.

.PARAMETER OutputPath
    Folder to write the CSV reports to. Defaults to C:\Temp\DFS-SiteCosting-Audit.

.EXAMPLE
    .\Get-DFSSiteCostingAudit.ps1 -NamespacePath "\\contoso.com\Public"

.EXAMPLE
    .\Get-DFSSiteCostingAudit.ps1 -NamespacePath "\\contoso.com\Public" -FolderPath "\\contoso.com\Public\Finance"

.NOTES
    Requires: ActiveDirectory PowerShell module, RSAT DFS Management Tools (DFSN module).
    Requires: Read rights to AD Sites and Services (Get-ADReplicationSubnet/SiteLink) and to
              the DFS namespace configuration.
    Safe/Read-only: makes no configuration changes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NamespacePath,

    [string]$FolderPath,

    [string]$OutputPath = "C:\Temp\DFS-SiteCosting-Audit"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---
foreach ($mod in "ActiveDirectory", "DFSN") {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' not found. Install RSAT for AD DS and DFS Management Tools." "ERROR"
        exit 1
    }
}
Import-Module ActiveDirectory -ErrorAction Stop
Import-Module DFSN -ErrorAction Stop

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"

# --- Subnet-to-site coverage (Layer 0) ---
Write-Status "Auditing AD subnet-to-site mappings..."
$subnets = Get-ADReplicationSubnet -Filter * -Properties Name, Site | Select-Object Name, @{N = 'Site'; E = { $_.Site } }
$unmappedSubnets = $subnets | Where-Object { -not $_.Site }

if ($unmappedSubnets) {
    Write-Status "$($unmappedSubnets.Count) subnet(s) with NO site mapping found — top cause of inconsistent referral routing." "WARN"
} else {
    Write-Status "All defined subnets have a site mapping." "OK"
}
$subnets | Export-Csv (Join-Path $OutputPath "subnets-$ts.csv") -NoTypeInformation

# --- Site link costs (Layer 2) ---
Write-Status "Auditing AD site link costs..."
$siteLinks = Get-ADReplicationSiteLink -Filter * -Properties Cost, SitesIncluded, ReplicationFrequencyInMinutes |
    Select-Object Name, Cost, @{N = 'Sites'; E = { $_.SitesIncluded -join ", " } }, ReplicationFrequencyInMinutes
$siteLinks | Format-Table -AutoSize
$siteLinks | Export-Csv (Join-Path $OutputPath "sitelinks-$ts.csv") -NoTypeInformation

$duplicateCostWarn = $siteLinks | Group-Object Cost | Where-Object { $_.Count -gt 1 }
if ($duplicateCostWarn) {
    Write-Status "Multiple site links share identical costs — verify this reflects intended equal-cost load spreading, not stale config." "WARN"
}

# --- Folder target priority overrides (Layer 3) ---
if ($FolderPath) {
    Write-Status "Auditing referral priority overrides for: $FolderPath"
    try {
        $targets = Get-DfsnFolderTarget -Path $FolderPath -ErrorAction Stop |
            Select-Object TargetPath, ReferralPriorityClass, ReferralPriorityRank, State
        $targets | Format-Table -AutoSize

        $overrides = $targets | Where-Object { $_.ReferralPriorityClass -ne "SiteCost" }
        if ($overrides) {
            Write-Status "$($overrides.Count) target(s) have a non-default (SiteCost) priority override — these outrank topology-based ordering entirely." "WARN"
        } else {
            Write-Status "All targets use default SiteCost ordering — no manual overrides in play." "OK"
        }
        $targets | Export-Csv (Join-Path $OutputPath "folder-targets-$ts.csv") -NoTypeInformation
    } catch {
        Write-Status "Could not query folder targets for $FolderPath. $_" "ERROR"
    }
} else {
    Write-Status "No -FolderPath supplied — skipping folder-target override audit. Namespace/site topology audit only." "INFO"
}

# --- Namespace referral ordering method (not exposed via DFSN cmdlets) ---
Write-Status "Namespace-level 'Referral Ordering Method' and 'Exclude targets outside client's site' are NOT exposed by DFSN PowerShell cmdlets — verify manually via DFS Management -> Namespace root Properties -> Referrals tab, or via 'dfsutil root export'." "WARN"

# --- Summary ---
Write-Host ""
Write-Status "=== SUMMARY ===" "INFO"
Write-Status "Subnets audited          : $($subnets.Count)" "INFO"
Write-Status "Subnets missing a site   : $($unmappedSubnets.Count)" $(if ($unmappedSubnets) { "WARN" } else { "OK" })
Write-Status "Site links audited       : $($siteLinks.Count)" "INFO"
Write-Status "Reports written to       : $OutputPath" "OK"
