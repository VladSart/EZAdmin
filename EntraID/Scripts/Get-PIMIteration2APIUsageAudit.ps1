<#
.SYNOPSIS
    Flags likely callers of the deprecated Microsoft Entra PIM "Iteration 2" beta APIs
    ahead of their October 28, 2026 retirement.

.DESCRIPTION
    Microsoft Entra Privileged Identity Management (PIM) Iteration 2 beta endpoints
    (/beta/privilegedAccess/aadRoles and /beta/privilegedAccess/azureResources) stop
    returning data on 2026-10-28. Microsoft Graph does not expose per-endpoint call
    telemetry via any supported API, so there is no way to directly query "who called
    this endpoint last month." This script instead audits the best available proxy
    signal: app registrations / service principals still holding the legacy
    PrivilegedAccess.* Graph application permissions that Iteration 2 required, which
    Iteration 3 does not use.

    This is a READ-ONLY audit and lead-generation tool, not an authoritative inventory.
    A flagged app MAY have an unrelated historical grant it no longer uses; an app with
    NO flagged grant could still be calling Iteration 2 endpoints under different,
    shared, or delegated credentials this script cannot see. Always confirm findings
    against actual source code / flow definitions before treating them as ground truth
    (see the Triage section of PIMIteration2Retirement-B.md for the source-grep step
    this script does not perform).

    It does NOT and cannot:
      - Read actual Graph API call logs or per-endpoint usage telemetry (no supported
        API surface exists for this).
      - Inspect Power Automate flow definitions, Logic App definitions, or third-party
        tool source code — those must be searched manually or via their own export tooling.
      - Modify any permission grant or migrate any code.

.PARAMETER OutputPath
    CSV path for the flagged service principal report. Default .\PIMIteration2UsageAudit.csv

.EXAMPLE
    .\Get-PIMIteration2APIUsageAudit.ps1
    Runs against the connected tenant and writes flagged app registrations to CSV.

.NOTES
    Requires: Microsoft.Graph.Applications module, connected with at minimum
              Application.Read.All and AppRoleAssignment.ReadWrite.All (read-level use only
              in this script; broader scope is a common admin-consent bundle, not a requirement
              this script itself needs write access for).
    Safe/unsafe: fully read-only. Safe to run at any time, including in production.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".\PIMIteration2UsageAudit.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Status "Microsoft.Graph.Applications module not found. Install with:`n    Install-Module Microsoft.Graph.Applications -Scope CurrentUser" "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) { throw "Not connected." }
    Write-Status "Connected to tenant $($context.TenantId) as $($context.Account)" "OK"
}
catch {
    Write-Status "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'Application.Read.All'" "ERROR"
    return
}

# ---- Detect: the legacy Iteration 2 permission scopes (Microsoft Graph app roles) ----
# These four scopes are specific to the deprecated /beta/privilegedAccess surface and
# are not used by any Iteration 3 (unifiedRole*, ARM) code path.
$legacyScopeNames = @(
    'PrivilegedAccess.Read.AzureAD',
    'PrivilegedAccess.ReadWrite.AzureAD',
    'PrivilegedAccess.Read.AzureResources',
    'PrivilegedAccess.ReadWrite.AzureResources'
)

Write-Status "Looking up the Microsoft Graph service principal to resolve legacy app role IDs..."
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
if (-not $graphSp) {
    Write-Status "Could not resolve the Microsoft Graph service principal in this tenant." "ERROR"
    return
}

$legacyAppRoles = $graphSp.AppRoles | Where-Object { $legacyScopeNames -contains $_.Value }
if (-not $legacyAppRoles -or $legacyAppRoles.Count -eq 0) {
    Write-Status "None of the legacy PrivilegedAccess.* app roles were found on the Graph service principal in this tenant — nothing to flag via this signal. Still confirm via source-code grep (see runbook)." "WARN"
    return
}
Write-Status "Resolved $($legacyAppRoles.Count) legacy app role definition(s) to check against." "OK"

# ---- Execute: enumerate all service principals' app role assignments FROM Graph ----
Write-Status "Enumerating tenant service principals and their Graph app role grants (this can take a while on large tenants)..."
$allServicePrincipals = Get-MgServicePrincipal -All

$flagged = foreach ($sp in $allServicePrincipals) {
    $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All -ErrorAction SilentlyContinue |
        Where-Object { $_.ResourceId -eq $graphSp.Id -and $legacyAppRoles.Id -contains $_.AppRoleId }

    foreach ($a in $assignments) {
        $roleName = ($legacyAppRoles | Where-Object Id -eq $a.AppRoleId).Value
        [pscustomobject]@{
            AppDisplayName   = $sp.DisplayName
            AppId            = $sp.AppId
            ServicePrincipalId = $sp.Id
            LegacyScope      = $roleName
            GrantCreatedDate = $a.CreatedDateTime
            AppOwnerOrgId    = $sp.AppOwnerOrganizationId
        }
    }
}

# ---- Validate / summarize ----
Write-Host ""
Write-Status "=== PIM Iteration 2 (Beta) API — Legacy Permission Exposure Summary ===" "INFO"
Write-Status "Retirement date: 2026-10-28 (Iteration 2 endpoints stop returning data)" "INFO"
Write-Status "Service principals audited: $($allServicePrincipals.Count)" "INFO"

if ($flagged.Count -eq 0) {
    Write-Status "No service principals hold legacy PrivilegedAccess.* Graph permissions. Low likelihood of Iteration 2 exposure via this signal — still confirm via source-code/flow-definition grep for the literal endpoint paths." "OK"
}
else {
    Write-Status "$($flagged.Count) legacy permission grant(s) found across $((($flagged | Select-Object -Unique AppId).Count)) app(s) — CONFIRM each against actual source/flow code before assuming active use." "WARN"
    $flagged | Sort-Object AppDisplayName | Format-Table AppDisplayName, LegacyScope, GrantCreatedDate -AutoSize
}

Write-Host ""
Write-Status "This script cannot see: actual API call activity, Power Automate/Logic App flow definitions, or third-party tool source code. Cross-reference flagged apps against PIMIteration2Retirement-B.md's Triage section before closing out." "INFO"

# ---- Report: export full CSV ----
if ($flagged.Count -gt 0) {
    $flagged | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Status "Flagged app list exported to $OutputPath" "OK"
}
