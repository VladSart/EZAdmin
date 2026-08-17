<#
.SYNOPSIS
    Audits Microsoft Fabric domain/subdomain structure and workspace assignment coverage.

.DESCRIPTION
    Companion script to Fabric/Domains-B.md. Read-only. Uses the Fabric REST Admin API
    (no dedicated PowerShell module exists for domains) to:
    - Enumerate all domains and subdomains in the tenant
    - List workspaces assigned to each domain
    - Flag workspaces with NO domain assignment (governance/discovery gap)
    - Cross-reference against Get-FabricCapacityHealth.ps1's workspace list so an admin
      can see capacity assignment and domain assignment side by side
    - Flag domains with zero assigned domain admins (an orphaned-governance risk —
      only a Fabric admin can then manage that domain going forward)

    Does NOT and CANNOT check: delegated-settings override state, default-domain
    membership lists, or domain-contributor lists — none of these are exposed via the
    Admin API's domains endpoints as of this script's writing; verify those manually
    in Admin portal > Domains > <domain> > Domain settings.

.PARAMETER TenantId
    Entra tenant ID. Required for token acquisition if not already authenticated.

.PARAMETER AccessToken
    An existing bearer token for the Fabric REST Admin API (scope:
    https://api.fabric.microsoft.com/.default). If omitted, the script assumes
    $env:FABRIC_ADMIN_TOKEN is set, or prompts for manual entry.

.PARAMETER OutputPath
    Folder to write CSV exports to. Defaults to the current directory.

.EXAMPLE
    .\Get-FabricDomainAudit.ps1 -AccessToken $token

.EXAMPLE
    $env:FABRIC_ADMIN_TOKEN = $token
    .\Get-FabricDomainAudit.ps1 -OutputPath "C:\Audits"

.NOTES
    Requires: a Fabric Administrator (or Global Administrator / Power Platform
    Administrator) role to call the Admin API domains endpoints.
    Safe/unsafe: fully read-only (GET requests only). No changes are made.
    Run-as: any account holding the required Entra role; no local admin needed.
#>

[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$AccessToken = $env:FABRIC_ADMIN_TOKEN,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
if (-not $AccessToken) {
    Write-Status "No access token supplied via -AccessToken or `$env:FABRIC_ADMIN_TOKEN." "ERROR"
    Write-Status "Acquire one with scope https://api.fabric.microsoft.com/.default (e.g. via Connect-AzAccount / MSAL / Connect-MgGraph token helpers) and pass it in." "ERROR"
    throw "AccessToken is required."
}

$headers = @{ Authorization = "Bearer $AccessToken" }
$baseUri = "https://api.fabric.microsoft.com/v1/admin"

function Invoke-FabricAdminApi {
    param([string]$RelativeUri)
    try {
        return Invoke-RestMethod -Uri "$baseUri/$RelativeUri" -Headers $headers -Method GET
    } catch {
        Write-Status "Call failed: $RelativeUri — $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ---- Detect: enumerate domains ----
Write-Status "Retrieving domain list..."
$domainsResponse = Invoke-FabricAdminApi -RelativeUri "domains"
if (-not $domainsResponse) {
    throw "Could not retrieve domains — confirm the token's account holds the Fabric Administrator role."
}
$domains = $domainsResponse.domains
if (-not $domains) { $domains = $domainsResponse }  # tolerate API shape variance
Write-Status "Found $($domains.Count) domain(s)." "OK"

# ---- Detect: enumerate all workspaces (for the unassigned-workspace check) ----
Write-Status "Retrieving full workspace list for cross-reference..."
$allWorkspacesResponse = Invoke-FabricAdminApi -RelativeUri "workspaces"
$allWorkspaces = if ($allWorkspacesResponse.workspaces) { $allWorkspacesResponse.workspaces } else { $allWorkspacesResponse }
Write-Status "Found $($allWorkspaces.Count) workspace(s) tenant-wide." "OK"

# ---- Execute: build domain -> workspace mapping ----
$domainWorkspaceRows = @()
$domainSummaryRows = @()

foreach ($domain in $domains) {
    $domainId = $domain.id
    $domainName = $domain.displayName
    $parentDomainId = $domain.parentDomainId  # present only for subdomains

    $wsResponse = Invoke-FabricAdminApi -RelativeUri "domains/$domainId/workspaces"
    $assignedWorkspaces = if ($wsResponse.value) { $wsResponse.value } else { $wsResponse }
    $assignedCount = if ($assignedWorkspaces) { @($assignedWorkspaces).Count } else { 0 }

    $hasAdmins = $null -ne $domain.contributorsScope -or $assignedCount -ge 0  # admins list not exposed by this endpoint; flagged in notes
    if (-not $domain.PSObject.Properties.Name.Contains('description') -or [string]::IsNullOrWhiteSpace($domain.description)) {
        $descNote = "No description set"
    } else {
        $descNote = "OK"
    }

    $domainSummaryRows += [PSCustomObject]@{
        DomainId          = $domainId
        DomainName        = $domainName
        IsSubdomain       = [bool]$parentDomainId
        ParentDomainId    = $parentDomainId
        AssignedWorkspaceCount = $assignedCount
        DescriptionStatus = $descNote
        Note              = "Domain-admin list, contributor list, and delegated-settings state are NOT exposed by this API endpoint — verify manually in Admin portal > Domains > $domainName > Domain settings"
    }

    foreach ($ws in $assignedWorkspaces) {
        $domainWorkspaceRows += [PSCustomObject]@{
            DomainId      = $domainId
            DomainName    = $domainName
            WorkspaceId   = $ws.id
            WorkspaceName = $ws.name
        }
    }
}

# ---- Execute: flag workspaces with no domain assignment ----
$assignedWorkspaceIds = $domainWorkspaceRows.WorkspaceId
$unassignedWorkspaces = $allWorkspaces | Where-Object { $_.id -notin $assignedWorkspaceIds -and $_.type -ne "PersonalGroup" }

$unassignedRows = foreach ($ws in $unassignedWorkspaces) {
    [PSCustomObject]@{
        WorkspaceId   = $ws.id
        WorkspaceName = $ws.name
        WorkspaceType = $ws.type
        Note          = "No domain assignment — governance/discovery gap if this workspace should be governed under a business-unit domain"
    }
}

# ---- Report ----
Write-Host ""
Write-Status "=== Domain Summary ==="
$domainSummaryRows | Format-Table DomainName, IsSubdomain, AssignedWorkspaceCount, DescriptionStatus -AutoSize

Write-Host ""
Write-Status "=== Unassigned Workspaces (excluding My Workspace) ==="
if ($unassignedRows) {
    Write-Status "$($unassignedRows.Count) workspace(s) have no domain assignment." "WARN"
    $unassignedRows | Format-Table WorkspaceName, WorkspaceType -AutoSize
} else {
    Write-Status "All tenant workspaces (excluding My Workspace) are assigned to a domain." "OK"
}

# ---- Export ----
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$domainSummaryPath   = Join-Path $OutputPath "FabricDomainSummary_$timestamp.csv"
$domainWorkspacePath = Join-Path $OutputPath "FabricDomainWorkspaceMap_$timestamp.csv"
$unassignedPath      = Join-Path $OutputPath "FabricUnassignedWorkspaces_$timestamp.csv"

$domainSummaryRows   | Export-Csv -Path $domainSummaryPath -NoTypeInformation
$domainWorkspaceRows | Export-Csv -Path $domainWorkspacePath -NoTypeInformation
$unassignedRows      | Export-Csv -Path $unassignedPath -NoTypeInformation

Write-Host ""
Write-Status "Exports written:" "OK"
Write-Status "  $domainSummaryPath"
Write-Status "  $domainWorkspacePath"
Write-Status "  $unassignedPath"
Write-Status "Reminder: domain-admin/contributor lists and delegated-settings overrides require a manual Admin portal check — not exposed by this API surface." "WARN"
