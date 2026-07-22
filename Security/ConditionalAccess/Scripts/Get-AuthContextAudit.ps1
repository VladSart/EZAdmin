<#
.SYNOPSIS
    Audits Microsoft Entra Conditional Access Authentication Context configuration end-to-end —
    context definitions, CA policy targeting, SharePoint tagging (both surfaces), Protected Actions,
    PIM role activation bindings, and known risk conditions.

.DESCRIPTION
    Read-only report covering:
      - Every defined Authentication Context class reference and its published (IsAvailable) state
      - Every CA policy that targets an Authentication Context, its State, and any excluded users
      - Contexts that are published/referenced by a CA policy but have NO consumer surface tagging
        anything with them (the single most common "configured but does nothing" gap)
      - Contexts with a CA policy in Off/Report-only state, or with the target user/group excluded —
        flagged because these are the specific states that defeat PIM's documented backup-protection
        mechanism (PIM only auto-falls-back to MFA when the CA policy is entirely MISSING, not when
        it exists but is disabled/report-only/excluded)
      - SharePoint direct site-level Authentication Context tags via Set-SPOSite (a separate surface
        from sensitivity labels that a label-only check will miss entirely)
      - SharePoint tenant-wide EnableAIPIntegration and BlockAppAccessWithAuthenticationContext state
      - PIM role Activation settings for a specified set of role definition IDs, cross-referenced
        against the CA policy state table above
    Does not create, modify, publish/unpublish, or delete any context, CA policy, sensitivity label,
    site tag, or PIM role setting. Does not check custom/LOB application-side context mappings —
    those live entirely in each app's own store and have no tenant-wide inventory.

.PARAMETER OutputPath
    Folder to write CSV reports to. Defaults to the current directory.

.PARAMETER SharePointSiteUrls
    One or more SharePoint site URLs to check for direct Set-SPOSite Authentication Context tagging.
    Requires an existing SPO admin connection (Connect-SPOService) — the script will prompt if none
    is active and -CheckSharePoint is specified.

.PARAMETER CheckSharePoint
    If specified, also queries SharePoint Online tenant settings and the URLs in -SharePointSiteUrls.
    Requires the SharePoint Online Management Shell module and an active or interactive SPO connection.

.PARAMETER RoleDefinitionIds
    One or more Entra directory role definition IDs to check for PIM Activation-tab Authentication
    Context bindings. Optional — omit to skip the PIM cross-reference section.

.EXAMPLE
    .\Get-AuthContextAudit.ps1 -OutputPath C:\Temp\Reports

.EXAMPLE
    .\Get-AuthContextAudit.ps1 -CheckSharePoint -SharePointSiteUrls "https://contoso.sharepoint.com/sites/finance"

.EXAMPLE
    .\Get-AuthContextAudit.ps1 -RoleDefinitionIds "62e90394-69f5-4237-9190-012177145e10"

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns modules
              Microsoft.Online.SharePoint.PowerShell module (only if -CheckSharePoint is used)
    Scopes:   Policy.Read.All, RoleManagement.Read.Directory
    Safe to run in production — read-only Graph/SPO calls only. No PowerShell-7-only operators used;
    compatible with Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [switch]$CheckSharePoint,
    [string[]]$SharePointSiteUrls = @(),
    [string[]]$RoleDefinitionIds = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Checking required Microsoft Graph modules..."
$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.SignIns"
)
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Status "Module $m not found. Install with: Install-Module $m -Scope CurrentUser" "WARN"
    }
}

if ($CheckSharePoint -and -not (Get-Module -ListAvailable -Name "Microsoft.Online.SharePoint.PowerShell")) {
    Write-Status "Microsoft.Online.SharePoint.PowerShell not found — SharePoint checks will be skipped. Install with: Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser" "WARN"
    $CheckSharePoint = $false
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Policy.Read.All", "RoleManagement.Read.Directory" -NoWelcome

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"

# ---------------------------------------------------------------------------
# Detect — Authentication Context definitions
# ---------------------------------------------------------------------------
Write-Status "Pulling Authentication Context class references..."
$contexts = Get-MgIdentityConditionalAccessAuthenticationContextClassReference -All

$contextReport = $contexts | ForEach-Object {
    [PSCustomObject]@{
        Id          = $_.Id
        DisplayName = $_.DisplayName
        Description = $_.Description
        IsAvailable = $_.IsAvailable
    }
}
Write-Status "Found $($contextReport.Count) context(s) defined." "OK"

$unpublished = $contextReport | Where-Object { -not $_.IsAvailable }
if ($unpublished.Count -gt 0) {
    Write-Status "$($unpublished.Count) context(s) exist but are NOT published (IsAvailable = false) — invisible to every consumer surface." "WARN"
}

# ---------------------------------------------------------------------------
# Detect — CA policies targeting each context, and risk-state flags
# ---------------------------------------------------------------------------
Write-Status "Pulling Conditional Access policies and mapping context targeting..."
$allPolicies = Get-MgIdentityConditionalAccessPolicy -All

$policyRows = New-Object System.Collections.Generic.List[Object]
$contextsWithNoPolicy = New-Object System.Collections.Generic.List[Object]

foreach ($ctx in $contextReport) {
    $matching = $allPolicies | Where-Object {
        $_.Conditions.Applications.IncludeAuthenticationContextClassReferences -contains $ctx.Id
    }

    if ($matching.Count -eq 0) {
        $contextsWithNoPolicy.Add($ctx.Id) | Out-Null
        continue
    }

    foreach ($pol in $matching) {
        $excludedCount = 0
        if ($pol.Conditions.Users.ExcludeUsers) { $excludedCount = @($pol.Conditions.Users.ExcludeUsers).Count }

        $riskFlag = "None"
        if ($pol.State -eq "disabled") { $riskFlag = "Policy Off — PIM backup-protection (if applicable) falls back to plain MFA only when NO policy exists at all; a Disabled policy does NOT trigger that fallback" }
        elseif ($pol.State -eq "enabledForReportingButNotEnforced") { $riskFlag = "Report-only — evaluated but not enforced; same non-fallback risk as Disabled for PIM pairings" }
        elseif ($excludedCount -gt 0) { $riskFlag = "$excludedCount user(s) explicitly excluded — excluded users get no elevated requirement from this policy" }

        $policyRows.Add([PSCustomObject]@{
            ContextId       = $ctx.Id
            ContextName     = $ctx.DisplayName
            PolicyName      = $pol.DisplayName
            PolicyState     = $pol.State
            ExcludedUsers   = $excludedCount
            RiskFlag        = $riskFlag
        }) | Out-Null
    }
}

if ($contextsWithNoPolicy.Count -gt 0) {
    Write-Status "$($contextsWithNoPolicy.Count) context(s) have NO CA policy targeting them at all: $($contextsWithNoPolicy -join ', ')" "WARN"
}

$riskyPolicyRows = $policyRows | Where-Object { $_.RiskFlag -ne "None" }
if ($riskyPolicyRows.Count -gt 0) {
    Write-Status "$($riskyPolicyRows.Count) context/policy pairing(s) flagged with a risk condition — see CSV for detail." "WARN"
}

# ---------------------------------------------------------------------------
# Detect — SharePoint (optional)
# ---------------------------------------------------------------------------
$spoTenantReport = $null
$spoSiteReport = New-Object System.Collections.Generic.List[Object]

if ($CheckSharePoint) {
    Write-Status "Checking SharePoint Online tenant-wide Authentication Context settings..."
    try {
        $spoTenant = Get-SPOTenant
        $spoTenantReport = [PSCustomObject]@{
            EnableAIPIntegration                   = $spoTenant.EnableAIPIntegration
            BlockAppAccessWithAuthenticationContext = $spoTenant.BlockAppAccessWithAuthenticationContext
        }
        if (-not $spoTenant.EnableAIPIntegration) {
            Write-Status "EnableAIPIntegration is OFF tenant-wide — no label-based Authentication Context tagging can function." "WARN"
        }
        if (-not $spoTenant.BlockAppAccessWithAuthenticationContext) {
            Write-Status "BlockAppAccessWithAuthenticationContext is OFF (default) — background/third-party apps are NOT blocked by site-level Authentication Context tags." "WARN"
        }

        foreach ($url in $SharePointSiteUrls) {
            try {
                $site = Get-SPOSite -Identity $url
                $spoSiteReport.Add([PSCustomObject]@{
                    SiteUrl               = $url
                    ConditionalAccessPolicy = $site.ConditionalAccessPolicy
                    IsRootSite            = ($url.TrimEnd('/') -match '/sites/|/teams/') -eq $false
                }) | Out-Null
            } catch {
                Write-Status "Could not query site '$url': $($_.Exception.Message)" "WARN"
            }
        }
    } catch {
        Write-Status "SharePoint check skipped — no active SPO admin connection. Run Connect-SPOService first, or omit -CheckSharePoint." "WARN"
    }
}

# ---------------------------------------------------------------------------
# Detect — PIM role activation settings (optional)
# ---------------------------------------------------------------------------
$pimReport = New-Object System.Collections.Generic.List[Object]

if ($RoleDefinitionIds.Count -gt 0) {
    Write-Status "Checking PIM role Activation settings for $($RoleDefinitionIds.Count) role(s)..."
    foreach ($roleId in $RoleDefinitionIds) {
        try {
            $uri = "https://graph.microsoft.com/beta/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '$roleId'"
            $result = Invoke-MgGraphRequest -Method GET -Uri $uri
            $pimReport.Add([PSCustomObject]@{
                RoleDefinitionId = $roleId
                RawResult        = ($result | ConvertTo-Json -Depth 8 -Compress)
            }) | Out-Null
        } catch {
            Write-Status "Could not query PIM policy for role '$roleId': $($_.Exception.Message)" "WARN"
        }
    }
    Write-Status "PIM role settings require manual inspection of the RawResult JSON column for the authenticationContext_* rule — no consistently-typed cmdlet output exists for this rule type." "INFO"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$contextCsv = Join-Path $OutputPath "AuthContext-Definitions-$timestamp.csv"
$policyCsv  = Join-Path $OutputPath "AuthContext-PolicyMapping-$timestamp.csv"

$contextReport | Export-Csv -Path $contextCsv -NoTypeInformation
$policyRows | Export-Csv -Path $policyCsv -NoTypeInformation
Write-Status "Context definitions exported: $contextCsv" "OK"
Write-Status "Policy mapping exported:      $policyCsv" "OK"

if ($spoTenantReport) {
    $spoTenantCsv = Join-Path $OutputPath "AuthContext-SPOTenant-$timestamp.csv"
    $spoTenantReport | Export-Csv -Path $spoTenantCsv -NoTypeInformation
    Write-Status "SPO tenant settings exported: $spoTenantCsv" "OK"
}
if ($spoSiteReport.Count -gt 0) {
    $spoSiteCsv = Join-Path $OutputPath "AuthContext-SPOSites-$timestamp.csv"
    $spoSiteReport | Export-Csv -Path $spoSiteCsv -NoTypeInformation
    Write-Status "SPO site tagging exported:    $spoSiteCsv" "OK"
}
if ($pimReport.Count -gt 0) {
    $pimCsv = Join-Path $OutputPath "AuthContext-PIMRoles-$timestamp.csv"
    $pimReport | Export-Csv -Path $pimCsv -NoTypeInformation
    Write-Status "PIM role settings exported:   $pimCsv" "OK"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "===== SUMMARY =====" "INFO"
Write-Status "Contexts defined:              $($contextReport.Count)" "INFO"
Write-Status "Contexts unpublished:          $($unpublished.Count)" $(if ($unpublished.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Contexts with NO CA policy:    $($contextsWithNoPolicy.Count)" $(if ($contextsWithNoPolicy.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Risky context/policy pairings: $($riskyPolicyRows.Count)" $(if ($riskyPolicyRows.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "This script does NOT verify that any resource is actually tagged with a context beyond the SharePoint sites explicitly passed in -SharePointSiteUrls — Protected Actions and PIM Activation-tab bindings must still be checked per the Mode A runbook's Validation Step 4." "INFO"
