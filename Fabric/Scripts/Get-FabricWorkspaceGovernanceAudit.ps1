<#
.SYNOPSIS
    Audits Microsoft Fabric workspace governance at scale: orphaned workspaces,
    naming-convention conformance, and (optionally) deleted/retention-window
    workspaces and workspace-level networking policy exposure.

.DESCRIPTION
    Companion script to Fabric/WorkspaceGovernance-B.md and -A.md. Read-only —
    makes zero write calls. Combines two data sources deliberately, because
    neither alone tells the complete governance story for this topic:

    - The MicrosoftPowerBIMgmt module's `Get-PowerBIWorkspace -Orphaned` switch,
      which is the AUTHORITATIVE, rate-limit-friendly source for orphaned-
      workspace detection. The Fabric REST Admin API's `state` field cannot be
      used for this — Microsoft's own schema documents that orphaned workspaces
      are reported as "Active" by that field (see WorkspaceGovernance-A.md,
      "How It Works" -> orphan-detection blind spot).
    - The Fabric REST Admin API (`List Workspaces`, `List Workspace Access
      Details`, `List Networking Communication Policies`) for everything the
      PowerBIMgmt module doesn't expose: naming-convention auditing against
      the full workspace list, deleted/retention-window enumeration, and a
      lightweight zero-Admin cross-check used to independently corroborate
      the PowerShell-reported orphan list (not to replace it — the REST path
      is rate-limited to 200 requests/hour on this endpoint and is capped by
      -MaxAccessDetailChecks to avoid exhausting that budget on a large tenant).

    Does NOT and CANNOT check: the live value of the "Create workspaces"
    tenant setting (portal-only, no REST/PowerShell read exists), Networking
    Communication Policy write history, or exact retention-expiry timestamps
    for Deleted workspaces (the API does not expose a deletion date) — verify
    those manually in Admin portal > Workspaces / Tenant settings.

    Makes NO write calls. Does not grant temporary access, does not restore
    or delete anything, does not assign roles.

.PARAMETER AccessToken
    A bearer token for the Fabric REST Admin API (scope:
    https://api.fabric.microsoft.com/.default). Required for the naming audit,
    the zero-Admin cross-check, and -IncludeDeleted. If omitted, the script
    still runs the authoritative PowerBIMgmt-based orphan detection but skips
    every REST-dependent section and reports that explicitly rather than
    silently producing an incomplete report.

.PARAMETER NamingPattern
    A regular expression every workspace display name is expected to match
    (e.g. '^[A-Z]{2,4}-(Dev|Test|Prod)-[A-Za-z0-9]+$'). If omitted, the naming
    audit section is skipped and reported as skipped, not silently empty.

.PARAMETER IncludeDeleted
    Switch. If set (and -AccessToken supplied), also enumerates workspaces
    currently in their post-deletion retention window via the REST Admin API
    (state=Deleted). Requires a separate call from the orphan/active audit.

.PARAMETER MaxAccessDetailChecks
    Caps how many workspaces get the REST-based zero-Admin cross-check (List
    Workspace Access Details), to protect the 200 requests/hour rate limit on
    that endpoint for large tenants. Default: 25. The PowerBIMgmt-based
    -Orphaned detection is unaffected by this cap and always runs in full.

.PARAMETER OutputPath
    Folder to write CSV exports to. Defaults to the current directory.

.EXAMPLE
    .\Get-FabricWorkspaceGovernanceAudit.ps1 -AccessToken $token -NamingPattern '^[A-Z]{2,4}-(Dev|Test|Prod)-.+$'

.EXAMPLE
    # Orphan detection only, no REST token available
    .\Get-FabricWorkspaceGovernanceAudit.ps1

.EXAMPLE
    $env:FABRIC_ADMIN_TOKEN = $token
    .\Get-FabricWorkspaceGovernanceAudit.ps1 -AccessToken $env:FABRIC_ADMIN_TOKEN -IncludeDeleted -OutputPath "C:\Audits"

.NOTES
    Requires: MicrosoftPowerBIMgmt module and a signed-in account holding the
    Fabric Administrator (or Power BI Administrator / Global Administrator)
    role for -Scope Organization calls. The -AccessToken (if supplied) needs
    a Fabric bearer token for the same privileged account or a service
    principal with Tenant.Read.All / Tenant.ReadWrite.All.
    Safe/unsafe: fully read-only (GET requests only, plus read-only
    PowerBIMgmt cmdlets). No changes are made to any workspace.
    Run-as: any account holding the required Entra/Fabric role; no local
    admin needed.
#>

[CmdletBinding()]
param(
    [string]$AccessToken = $env:FABRIC_ADMIN_TOKEN,
    [string]$NamingPattern,
    [switch]$IncludeDeleted,
    [int]$MaxAccessDetailChecks = 25,
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
Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop
if (-not (Get-PowerBIAccessToken -ErrorAction SilentlyContinue)) {
    Write-Status "No active Power BI/Fabric session — connecting interactively." "INFO"
    Connect-PowerBIServiceAccount | Out-Null
}

$restHeaders = $null
if ($AccessToken) {
    $restHeaders = @{ Authorization = "Bearer $AccessToken" }
} else {
    Write-Status "No -AccessToken (or `$env:FABRIC_ADMIN_TOKEN) supplied. Orphan detection via the" "WARN"
    Write-Status "PowerBIMgmt module will still run in full, but the naming audit, the REST" "WARN"
    Write-Status "zero-Admin cross-check, and -IncludeDeleted will be skipped and reported as such." "WARN"
}

$restBase = "https://api.fabric.microsoft.com/v1/admin/workspaces"

function Invoke-FabricAdminApi {
    param([string]$Uri)
    try {
        return Invoke-RestMethod -Uri $Uri -Headers $restHeaders -Method GET
    } catch {
        Write-Status "REST call failed: $Uri — $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# ==========================================================================
# Section 1 — Orphan detection (authoritative: PowerBIMgmt -Orphaned switch)
# ==========================================================================
Write-Status "Retrieving orphaned workspaces via Get-PowerBIWorkspace -Orphaned (authoritative)..."
$orphanedWorkspaces = @(Get-PowerBIWorkspace -Scope Organization -Orphaned -All)
Write-Status "Found $($orphanedWorkspaces.Count) orphaned workspace(s)." $(if ($orphanedWorkspaces.Count -gt 0) { "WARN" } else { "OK" })

$orphanRows = foreach ($ws in $orphanedWorkspaces) {
    [PSCustomObject]@{
        WorkspaceId   = $ws.Id
        WorkspaceName = $ws.Name
        WorkspaceType = $ws.Type
        Note          = "No Admin assigned — content unaffected, administration blocked. Recover via Add-PowerBIWorkspaceUser -AccessRight Admin."
    }
}

# ==========================================================================
# Section 2 — Full workspace inventory (REST) for naming audit + cross-check
# ==========================================================================
$allWorkspacesRest = @()
if ($restHeaders) {
    Write-Status "Retrieving full workspace list via REST Admin API (paginated)..."
    $uri = "$restBase"
    do {
        $page = Invoke-FabricAdminApi -Uri $uri
        if (-not $page) { break }
        $allWorkspacesRest += $page.workspaces
        $uri = $page.continuationUri
    } while ($uri)
    Write-Status "Retrieved $($allWorkspacesRest.Count) workspace(s) tenant-wide via REST." "OK"
} else {
    Write-Status "Skipping REST workspace inventory (no AccessToken) — naming audit will not run." "WARN"
}

# ---- Naming convention audit ----
$namingViolationRows = @()
if ($NamingPattern -and $allWorkspacesRest.Count -gt 0) {
    Write-Status "Auditing workspace names against pattern: $NamingPattern"
    $violations = $allWorkspacesRest | Where-Object {
        $_.type -eq "Workspace" -and $_.name -notmatch $NamingPattern
    }
    Write-Status "$($violations.Count) workspace(s) do not match the naming pattern." $(if ($violations.Count -gt 0) { "WARN" } else { "OK" })
    $namingViolationRows = foreach ($ws in $violations) {
        [PSCustomObject]@{
            WorkspaceId   = $ws.id
            WorkspaceName = $ws.name
            CapacityId    = $ws.capacityId
            DomainId      = $ws.domainId
            Note          = "Does not match required pattern '$NamingPattern' — no platform enforcement exists; route to owning Admin for a rename."
        }
    }
} elseif (-not $NamingPattern) {
    Write-Status "No -NamingPattern supplied — naming audit skipped (not silently empty; this is deliberate)." "WARN"
}

# ==========================================================================
# Section 3 — Zero-Admin cross-check via List Workspace Access Details
#              (capped by -MaxAccessDetailChecks to protect the 200/hr limit)
# ==========================================================================
$crossCheckRows = @()
if ($restHeaders -and $allWorkspacesRest.Count -gt 0) {
    $activeWorkspaces = $allWorkspacesRest | Where-Object { $_.type -eq "Workspace" } | Select-Object -First $MaxAccessDetailChecks
    Write-Status "Cross-checking Admin roster for up to $MaxAccessDetailChecks workspace(s) via REST (200 req/hour cap on this endpoint)..."
    $checked = 0
    foreach ($ws in $activeWorkspaces) {
        $access = Invoke-FabricAdminApi -Uri "$restBase/$($ws.id)/users"
        $checked++
        if (-not $access) { continue }
        $adminCount = @($access.accessDetails | Where-Object { $_.workspaceAccessDetails.workspaceRole -eq "Admin" }).Count
        if ($adminCount -eq 0) {
            $crossCheckRows += [PSCustomObject]@{
                WorkspaceId   = $ws.id
                WorkspaceName = $ws.name
                AdminCount    = 0
                Note          = "Zero Admins confirmed via REST — should also appear in the Section 1 orphan list. Flag any discrepancy for investigation."
            }
        }
    }
    Write-Status "Checked $checked workspace(s); $($crossCheckRows.Count) confirmed zero-Admin via REST." $(if ($crossCheckRows.Count -gt 0) { "WARN" } else { "OK" })
    if ($allWorkspacesRest.Count -gt $MaxAccessDetailChecks) {
        Write-Status "Note: $($allWorkspacesRest.Count - $MaxAccessDetailChecks) workspace(s) were NOT cross-checked via REST (cap reached) — Section 1's PowerBIMgmt-based detection still covers the full tenant regardless." "WARN"
    }
} elseif ($restHeaders) {
    Write-Status "Skipping REST zero-Admin cross-check — no workspaces retrieved in Section 2." "WARN"
}

# ==========================================================================
# Section 4 — Deleted / retention-window workspaces (optional)
# ==========================================================================
$deletedRows = @()
if ($IncludeDeleted) {
    if (-not $restHeaders) {
        Write-Status "-IncludeDeleted was specified but no AccessToken is available — skipping." "WARN"
    } else {
        Write-Status "Retrieving Deleted-state (retention-window) workspaces via REST..."
        $deletedWorkspaces = @()
        $uri = "$restBase`?state=Deleted"
        do {
            $page = Invoke-FabricAdminApi -Uri $uri
            if (-not $page) { break }
            $deletedWorkspaces += $page.workspaces
            $uri = $page.continuationUri
        } while ($uri)
        Write-Status "Found $($deletedWorkspaces.Count) workspace(s) in a retention window." $(if ($deletedWorkspaces.Count -gt 0) { "WARN" } else { "OK" })
        $deletedRows = foreach ($ws in $deletedWorkspaces) {
            [PSCustomObject]@{
                WorkspaceId   = $ws.id
                WorkspaceName = $ws.name
                WorkspaceType = $ws.type
                Note          = "In retention window (exact expiry not exposed by this API — verify remaining days in Admin portal > Workspaces). $(if ($ws.type -eq 'Personal') { 'Fixed 30-day retention (My workspace).' } else { 'Configurable 7-90 day retention (collaborative workspace).' })"
            }
        }
    }
}

# ---- Report ----
Write-Host ""
Write-Status "=== Orphaned Workspaces (authoritative) ==="
if ($orphanRows) { $orphanRows | Format-Table WorkspaceName, WorkspaceType -AutoSize } else { Write-Status "None found." "OK" }

Write-Host ""
Write-Status "=== Naming Convention Violations ==="
if ($NamingPattern) {
    if ($namingViolationRows) { $namingViolationRows | Format-Table WorkspaceName -AutoSize } else { Write-Status "None found (or naming audit skipped — see above)." "OK" }
} else {
    Write-Status "Skipped — no -NamingPattern supplied." "WARN"
}

Write-Host ""
Write-Status "=== REST Zero-Admin Cross-Check (subset, capped) ==="
if ($crossCheckRows) { $crossCheckRows | Format-Table WorkspaceName, AdminCount -AutoSize } else { Write-Status "None found in the checked subset." "OK" }

if ($IncludeDeleted) {
    Write-Host ""
    Write-Status "=== Deleted / Retention-Window Workspaces ==="
    if ($deletedRows) { $deletedRows | Format-Table WorkspaceName, WorkspaceType -AutoSize } else { Write-Status "None found." "OK" }
}

# ---- Export ----
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$orphanPath     = Join-Path $OutputPath "FabricOrphanedWorkspaces_$timestamp.csv"
$namingPath     = Join-Path $OutputPath "FabricNamingViolations_$timestamp.csv"
$crossCheckPath = Join-Path $OutputPath "FabricZeroAdminCrossCheck_$timestamp.csv"
$deletedPath    = Join-Path $OutputPath "FabricDeletedWorkspaces_$timestamp.csv"

$orphanRows      | Export-Csv -Path $orphanPath -NoTypeInformation
$namingViolationRows | Export-Csv -Path $namingPath -NoTypeInformation
$crossCheckRows  | Export-Csv -Path $crossCheckPath -NoTypeInformation
if ($IncludeDeleted) { $deletedRows | Export-Csv -Path $deletedPath -NoTypeInformation }

Write-Host ""
Write-Status "Exports written:" "OK"
Write-Status "  $orphanPath"
Write-Status "  $namingPath"
Write-Status "  $crossCheckPath"
if ($IncludeDeleted) { Write-Status "  $deletedPath" }
Write-Status "Reminder: the 'Create workspaces' tenant setting's live scope, exact retention-expiry dates, and Networking Communication Policy write history all require a manual Admin portal check — not exposed by this API surface." "WARN"
