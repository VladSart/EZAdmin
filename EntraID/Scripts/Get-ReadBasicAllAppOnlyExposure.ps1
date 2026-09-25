<#
.SYNOPSIS
    Inventories every app holding Microsoft Graph User.ReadBasic.All (delegated AND application)
    and flags whether each already holds a MC1470871 replacement permission.

.DESCRIPTION
    Message Center MC1470871 (published 2026-09-11, rollout mid- to late September 2026)
    removes read access to user app role assignments and user license details from the
    Microsoft Graph permission User.ReadBasic.All, in both its delegated and its
    application (app-only) forms.

    The earlier Get-ReadBasicAllUsageAudit.ps1 only enumerates delegated
    (oAuth2PermissionGrant) consent. This script covers both consent types:
      - Delegated: oAuth2PermissionGrants whose scope string contains User.ReadBasic.All
        (AllPrincipals = tenant-wide admin consent, Principal = per-user consent, aggregated)
      - Application: appRoleAssignments on the Microsoft Graph service principal for the
        User.ReadBasic.All app role

    For each client app it reports whether the SAME grant type also holds a permission that
    keeps the removed data reachable after the fix:
      - User.Read.All, Directory.Read.All, Directory.ReadWrite.All   (app role assignments)
      - LicenseAssignment.Read.All / LicenseAssignment.ReadWrite.All (license details)
    Rows where no replacement exists are flagged RiskLevel HIGH (application or tenant-wide
    delegated) or MEDIUM (per-user delegated only).

    What it does NOT do:
      - It cannot tell what an app's code actually calls. Use Microsoft Graph activity logs
        (KQL in ReadBasicAllScopeChange-A.md, Validation step 4) or code review for that.
      - It does not modify any grant or consent.

.PARAMETER OutputPath
    Folder for the CSV export. Default: current directory.

.PARAMETER IncludeMicrosoftApps
    Include first-party Microsoft service principals (owner tenant f8cdef31-a31e-4b4a-93e4-5f571e91255a).
    They're excluded by default because Microsoft remediates its own apps.

.EXAMPLE
    .\Get-ReadBasicAllAppOnlyExposure.ps1
    Inventories the connected tenant and writes ReadBasicAllExposure-<timestamp>.csv.

.EXAMPLE
    .\Get-ReadBasicAllAppOnlyExposure.ps1 -OutputPath C:\Audits -IncludeMicrosoftApps

.NOTES
    Requires : Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
               Microsoft.Graph.Identity.SignIns modules (SDK v2.x)
    Scopes   : Application.Read.All, DelegatedPermissionGrant.Read.All (read-only)
    Role     : Global Reader, Cloud Application Administrator or equivalent
    Safety   : Fully read-only. Safe to run in production.
    Related  : EntraID/Graph/ReadBasicAllScopeChange-A.md / -B.md
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Get-Location).Path,
    [switch]$IncludeMicrosoftApps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$graphAppId       = '00000003-0000-0000-c000-000000000000'
$msftOwnerTenant  = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'
$target           = 'User.ReadBasic.All'
$roleReplacements = @('User.Read.All', 'User.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
$licReplacements  = @('LicenseAssignment.Read.All', 'LicenseAssignment.ReadWrite.All') + $roleReplacements

# ---------------- Preflight ----------------
Write-Status "Preflight: checking modules and connection"
foreach ($m in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Identity.SignIns') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module $m not installed. Install-Module $m -Scope CurrentUser" }
}
if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$ctx = Get-MgContext
if (-not $ctx) {
    Connect-MgGraph -Scopes "Application.Read.All", "DelegatedPermissionGrant.Read.All" -NoWelcome
    $ctx = Get-MgContext
}
Write-Status "Connected to tenant $($ctx.TenantId) as $($ctx.Account)" "OK"

# ---------------- Detect: resolve permission definitions live ----------------
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
if (-not $graphSp) { throw "Microsoft Graph service principal not found in tenant." }

$delegatedDef = $graphSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq $target }
$appRoleDef   = $graphSp.AppRoles | Where-Object { $_.Value -eq $target -and $_.AllowedMemberTypes -contains 'Application' }
if (-not $delegatedDef) { Write-Status "Delegated definition for $target not found" "WARN" } else { Write-Status "Delegated $target id: $($delegatedDef.Id)" }
if (-not $appRoleDef)   { Write-Status "Application definition for $target not found" "WARN" } else { Write-Status "Application $target id: $($appRoleDef.Id)" }

$appRoleValueById = @{}
foreach ($r in $graphSp.AppRoles) { $appRoleValueById[[string]$r.Id] = $r.Value }

$spCache = @{}
function Get-SpCached([string]$Id) {
    if (-not $spCache.ContainsKey($Id)) {
        $spCache[$Id] = Get-MgServicePrincipal -ServicePrincipalId $Id -Property id,appId,displayName,appOwnerOrganizationId,servicePrincipalType,accountEnabled -ErrorAction SilentlyContinue
    }
    return $spCache[$Id]
}

$results = New-Object System.Collections.Generic.List[object]

# ---------------- Execute: delegated grants ----------------
Write-Status "Enumerating delegated grants to Microsoft Graph (may take a while in large tenants)"
$grants = @(Get-MgOauth2PermissionGrant -Filter "resourceId eq '$($graphSp.Id)'" -All)
$delegatedHits = @($grants | Where-Object { ($_.Scope -split ' ') -contains $target })
Write-Status "Delegated grants containing ${target}: $($delegatedHits.Count)"

foreach ($clientGroup in ($delegatedHits | Group-Object ClientId)) {
    $sp = Get-SpCached $clientGroup.Name
    if (-not $sp) { continue }
    if (-not $IncludeMicrosoftApps -and [string]$sp.AppOwnerOrganizationId -eq $msftOwnerTenant) { continue }

    # All delegated scopes this client holds on Graph (any grant), for the replacement check
    $allScopes = @($grants | Where-Object { $_.ClientId -eq $clientGroup.Name } |
                   ForEach-Object { $_.Scope -split ' ' } | Where-Object { $_ } | Select-Object -Unique)
    $tenantWide = @($clientGroup.Group | Where-Object ConsentType -eq 'AllPrincipals').Count -gt 0
    $perUser    = @($clientGroup.Group | Where-Object ConsentType -eq 'Principal').Count

    $hasRole = @($allScopes | Where-Object { $roleReplacements -contains $_ }).Count -gt 0
    $hasLic  = @($allScopes | Where-Object { $licReplacements  -contains $_ }).Count -gt 0
    $risk = if ($hasRole -and $hasLic) { 'LOW' } elseif ($tenantWide) { 'HIGH' } else { 'MEDIUM' }

    $results.Add([pscustomobject]@{
        GrantType                  = 'Delegated'
        AppDisplayName             = $sp.DisplayName
        AppId                      = $sp.AppId
        ServicePrincipalId         = $sp.Id
        ServicePrincipalType       = $sp.ServicePrincipalType
        AccountEnabled             = $sp.AccountEnabled
        MicrosoftFirstParty        = ([string]$sp.AppOwnerOrganizationId -eq $msftOwnerTenant)
        TenantWideConsent          = $tenantWide
        PerUserConsentCount        = $perUser
        ReplacementForAppRoles     = $hasRole
        ReplacementForLicenses     = $hasLic
        RiskLevel                  = $risk
        OtherGraphPermissions      = (($allScopes | Where-Object { $_ -ne $target }) -join ' ')
    })
}

# ---------------- Execute: application permissions ----------------
if ($appRoleDef) {
    Write-Status "Enumerating application (app-only) assignments on Microsoft Graph"
    $assignedTo = @(Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $graphSp.Id -All)
    $appHits = @($assignedTo | Where-Object { [string]$_.AppRoleId -eq [string]$appRoleDef.Id })
    Write-Status "Application assignments of ${target}: $($appHits.Count)"

    foreach ($hit in $appHits) {
        $sp = Get-SpCached ([string]$hit.PrincipalId)
        if (-not $sp) { continue }
        if (-not $IncludeMicrosoftApps -and [string]$sp.AppOwnerOrganizationId -eq $msftOwnerTenant) { continue }

        $held = @($assignedTo | Where-Object { [string]$_.PrincipalId -eq [string]$hit.PrincipalId } |
                  ForEach-Object { $appRoleValueById[[string]$_.AppRoleId] } | Where-Object { $_ } | Select-Object -Unique)
        $hasRole = @($held | Where-Object { $roleReplacements -contains $_ }).Count -gt 0
        $hasLic  = @($held | Where-Object { $licReplacements  -contains $_ }).Count -gt 0
        $risk = if ($hasRole -and $hasLic) { 'LOW' } else { 'HIGH' }

        $results.Add([pscustomobject]@{
            GrantType                  = 'Application'
            AppDisplayName             = $sp.DisplayName
            AppId                      = $sp.AppId
            ServicePrincipalId         = $sp.Id
            ServicePrincipalType       = $sp.ServicePrincipalType
            AccountEnabled             = $sp.AccountEnabled
            MicrosoftFirstParty        = ([string]$sp.AppOwnerOrganizationId -eq $msftOwnerTenant)
            TenantWideConsent          = $true
            PerUserConsentCount        = 0
            ReplacementForAppRoles     = $hasRole
            ReplacementForLicenses     = $hasLic
            RiskLevel                  = $risk
            OtherGraphPermissions      = (($held | Where-Object { $_ -ne $target }) -join ' ')
        })
    }
}

# ---------------- Validate & Report ----------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv   = Join-Path $OutputPath "ReadBasicAllExposure-$stamp.csv"
$results | Sort-Object @{e={ switch ($_.RiskLevel) { 'HIGH' {0} 'MEDIUM' {1} default {2} } }}, GrantType, AppDisplayName |
    Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

$high = @($results | Where-Object RiskLevel -eq 'HIGH').Count
$med  = @($results | Where-Object RiskLevel -eq 'MEDIUM').Count
$low  = @($results | Where-Object RiskLevel -eq 'LOW').Count
$appOnly = @($results | Where-Object GrantType -eq 'Application').Count

Write-Host ""
Write-Status "Apps holding ${target}: $($results.Count)  (application: $appOnly)"
if ($high -gt 0) { Write-Status "HIGH   : $high (no replacement permission, app-only or tenant-wide)" "WARN" }
if ($med  -gt 0) { Write-Status "MEDIUM : $med (per-user delegated only, no replacement)" "WARN" }
Write-Status "LOW    : $low (already holds replacement permissions)" "OK"
Write-Status "CSV    : $csv" "OK"
Write-Status "Next: confirm real usage with MicrosoftGraphActivityLogs (ReadBasicAllScopeChange-A.md, Validation step 4) before changing any grant." "INFO"
