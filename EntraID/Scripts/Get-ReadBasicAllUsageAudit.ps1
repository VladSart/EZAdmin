<#
.SYNOPSIS
    Read-only audit of which apps in the tenant hold the User.ReadBasic.All delegated
    Graph permission, ahead of Microsoft's September 2026 permission-scope security fix.

.DESCRIPTION
    Microsoft's "What's new in Microsoft Entra: September 2026" post confirms that
    User.ReadBasic.All has been accidentally granting apps read access to appRoleAssignments
    and license details in addition to its intended basic-profile-only scope, and that this
    extra access is being removed as a security fix. See EntraID/Graph/ReadBasicAllScopeChange-B.md
    for full context, remediation guidance, and sources.

    This script:
      - Live-resolves the current User.ReadBasic.All scope definition directly from the
        tenant's own Microsoft Graph service principal (never hardcodes a permission GUID)
      - Enumerates every OAuth2 delegated permission grant in the tenant that includes
        User.ReadBasic.All, tenant-wide (AllPrincipals) or per-user (Principal) consent
      - Resolves the consenting client app's display name, AppId, and (where present)
        the specific user who granted per-user consent
      - Flags each grant as HIGH (tenant-wide/admin consent) or MEDIUM (per-user consent)
        risk based on blast radius, not on confirmed misuse — this script cannot determine
        what an app's code actually reads, only what it is authorized to read
      - Optionally cross-references whether the same app ALSO independently holds
        AppRoleAssignment.Read* or License*.Read* permissions, as a weak signal for
        whether it may have been relying on User.ReadBasic.All for that data instead

    This script does NOT modify any permission grants and does NOT determine actual app
    behavior — it is a starting inventory for the manual/vendor confirmation step described
    in ReadBasicAllScopeChange-B.md Fix 1/2/3.

.PARAMETER OutputPath
    Optional. Folder to write the CSV export to. Defaults to the current directory.

.EXAMPLE
    .\Get-ReadBasicAllUsageAudit.ps1

.EXAMPLE
    .\Get-ReadBasicAllUsageAudit.ps1 -OutputPath "C:\Audits\Sep2026"

.NOTES
    Requires: Microsoft.Graph.Applications, Microsoft.Graph.Identity.SignIns PowerShell modules
    Run as: any account with Directory.Read.All / Application.Read.All / DelegatedPermissionGrant.Read.All
    Safe/unsafe: fully read-only, safe to run in production at any time
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
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
Write-Status "Checking Microsoft Graph PowerShell connection..."
try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "Not connected" }
}
catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "DelegatedPermissionGrant.Read.All", "Application.Read.All", "Directory.Read.All" -NoWelcome
    $ctx = Get-MgContext
}
Write-Status "Connected as $($ctx.Account) to tenant $($ctx.TenantId)" "OK"

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "Output path '$OutputPath' does not exist — creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Step 1 — Live-resolve the current User.ReadBasic.All scope definition
# ---------------------------------------------------------------------------
Write-Status "Resolving current User.ReadBasic.All scope definition from the Microsoft Graph service principal..."

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -ErrorAction Stop
$readBasicScope = $graphSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq "User.ReadBasic.All" }

if (-not $readBasicScope) {
    Write-Status "Could not find User.ReadBasic.All in this tenant's Microsoft Graph service principal — unexpected. Aborting." "ERROR"
    return
}

Write-Status "Live scope definition:" "OK"
Write-Host "  Id                      : $($readBasicScope.Id)"
Write-Host "  AdminConsentDisplayName : $($readBasicScope.AdminConsentDisplayName)"
Write-Host "  AdminConsentDescription : $($readBasicScope.AdminConsentDescription)"
Write-Host ""
Write-Host "  Compare this description against the wording quoted in ReadBasicAllScopeChange-B.md." -ForegroundColor DarkGray
Write-Host "  If Microsoft has updated it to explicitly exclude appRoleAssignments/license data," -ForegroundColor DarkGray
Write-Host "  that's a signal the fix has already rolled out to this tenant." -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# Step 2 — Enumerate every delegated permission grant including User.ReadBasic.All
# ---------------------------------------------------------------------------
Write-Status "Enumerating OAuth2 delegated permission grants tenant-wide (this can take a while in large tenants)..."

$allGrants = Get-MgOauth2PermissionGrant -All
$flaggedGrants = $allGrants | Where-Object { $_.Scope -match '(?<![\w.])User\.ReadBasic\.All(?![\w.])' }

Write-Status "Found $($flaggedGrants.Count) grant(s) referencing User.ReadBasic.All out of $($allGrants.Count) total delegated grants." "OK"

if ($flaggedGrants.Count -eq 0) {
    Write-Status "No apps in this tenant currently hold User.ReadBasic.All. Nothing to remediate." "OK"
    return
}

# ---------------------------------------------------------------------------
# Step 3 — Resolve client app details and (weak-signal) related permissions
# ---------------------------------------------------------------------------
Write-Status "Resolving client app details for each flagged grant..."

$results = foreach ($grant in $flaggedGrants) {

    $client = $null
    try { $client = Get-MgServicePrincipal -ServicePrincipalId $grant.ClientId -ErrorAction Stop } catch {}

    $principalUpn = $null
    if ($grant.ConsentType -eq "Principal" -and $grant.PrincipalId) {
        try {
            $principalUpn = (Get-MgUser -UserId $grant.PrincipalId -Property UserPrincipalName -ErrorAction Stop).UserPrincipalName
        }
        catch { $principalUpn = "<could not resolve>" }
    }

    # Weak signal only: does this app ALSO hold an app-role-assignment or license-read
    # permission independently? If yes, less likely to have been relying solely on
    # User.ReadBasic.All for that data. If no, worth a closer look.
    $hasIndependentAppRoleOrLicenseScope = $false
    try {
        $ownGrants = $allGrants | Where-Object { $_.ClientId -eq $grant.ClientId }
        $combinedScopes = ($ownGrants.Scope -join " ")
        if ($combinedScopes -match '(?i)(AppRoleAssignment\.Read|User\.Read\.All|LicenseAssignment\.Read|License\.Read)') {
            $hasIndependentAppRoleOrLicenseScope = $true
        }
    }
    catch {}

    $riskLevel = if ($grant.ConsentType -eq "AllPrincipals") { "HIGH (tenant-wide admin consent)" } else { "MEDIUM (per-user consent)" }

    [pscustomobject]@{
        AppDisplayName                    = if ($client) { $client.DisplayName } else { "<could not resolve>" }
        AppId                             = if ($client) { $client.AppId } else { $grant.ClientId }
        ConsentType                       = $grant.ConsentType
        ConsentingUser                    = $principalUpn
        FullScopeGranted                  = $grant.Scope.Trim()
        RiskLevel                         = $riskLevel
        AlreadyHasIndependentAppRoleOrLicenseScope = $hasIndependentAppRoleOrLicenseScope
        ReviewStatus                      = "NOT YET REVIEWED — see ReadBasicAllScopeChange-B.md Fix 1/2/3"
    }
}

$results | Sort-Object RiskLevel, AppDisplayName | Format-Table -AutoSize

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path -Path $OutputPath -ChildPath "ReadBasicAllUsageAudit-$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Status "Exported $($results.Count) flagged grant(s) to: $csvPath" "OK"
Write-Status "Next step: for each app, confirm with the vendor or via code review whether it relies on appRoleAssignments or license data through User.ReadBasic.All, then follow Fix 1/2/3 in ReadBasicAllScopeChange-B.md." "WARN"
