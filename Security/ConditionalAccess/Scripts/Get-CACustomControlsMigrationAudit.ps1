<#
.SYNOPSIS
    Audits a tenant's Conditional Access Custom Controls usage and External MFA migration readiness
    ahead of the September 2026 creation/modification freeze and May 2027 functional retirement.

.DESCRIPTION
    Per Microsoft 365 Message Center announcement MC1422061, Conditional Access Custom Controls (the
    legacy third-party-MFA-redirect grant mechanism) are being retired. This script answers the two
    questions every tenant needs to answer before that timeline matters:
      1. Impact assessment — does this tenant have ANY Conditional Access policy referencing a Custom
         Control grant control at all? (Most tenants using native Entra MFA/FIDO2/WHfB do not.)
      2. Migration readiness — for each affected policy, has a corresponding External Authentication
         Method (External MFA) already been configured, and is it fully consented and enabled?

    This script deliberately does NOT and CANNOT resolve which specific third-party provider a given
    Custom Control points to — that detail lives only in the Entra admin center's Custom Controls
    (Preview) UI blade, not in any Graph-queryable property at the same fidelity External MFA exposes.
    Flag affected policies here, then cross-reference the admin center manually per policy. See
    CustomControlsRetirement-A.md "How It Works" for why this asymmetry exists.

    Also does NOT validate: OIDC handshake health, acr/amr claim correctness, or provider certificate
    rotation timing for any already-configured External MFA method — use Get-ExternalMFAAudit.ps1
    (EntraID/Scripts/) for that once a migration target is actually being stood up.

.PARAMETER OutputPath
    Directory to write the CSV/JSON reports to. Defaults to the current directory.

.EXAMPLE
    .\Get-CACustomControlsMigrationAudit.ps1
    Runs the full impact assessment and migration-readiness cross-check against the current tenant.

.EXAMPLE
    .\Get-CACustomControlsMigrationAudit.ps1 -OutputPath C:\Audits\CACustomControls
    Same, writing reports to a specific folder.

.NOTES
    Requires: Microsoft.Graph.Identity.SignIns module
    Scopes:   Policy.Read.All
    Safe/read-only: Yes — makes no configuration changes and no outbound calls to third parties.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---
try {
    $ctx = Get-MgContext
    if (-not $ctx) { throw "Not connected." }
    Write-Status "Connected to tenant: $($ctx.TenantId)" "OK"
} catch {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'Policy.Read.All' first." "ERROR"
    return
}

$requiredScopes = @("Policy.Read.All")
$missing = $requiredScopes | Where-Object { $_ -notin $ctx.Scopes }
if ($missing) {
    Write-Status "Missing required scope(s): $($missing -join ', '). Re-run Connect-MgGraph with these scopes." "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmm'

# --- Retirement timeline reference (informational — not enforced against system clock, since the
#     script may be run for forward planning ahead of either date) ---
$creationFreezeDate  = Get-Date -Year 2026 -Month 9 -Day 1
$fullRetirementDate  = Get-Date -Year 2027 -Month 5 -Day 1
$today = Get-Date

Write-Status "Retirement timeline: creation/modification freeze $($creationFreezeDate.ToString('yyyy-MM-dd')), full functional retirement $($fullRetirementDate.ToString('yyyy-MM-dd'))." "INFO"
if ($today -ge $fullRetirementDate) {
    Write-Status "Today is ON OR PAST the full retirement date — any policy flagged below has already lost its Custom Control grant." "ERROR"
} elseif ($today -ge $creationFreezeDate) {
    Write-Status "Today is inside the frozen window — Custom Controls cannot be created or modified. Existing ones still function until full retirement." "WARN"
} else {
    Write-Status "Today is before the creation/modification freeze. Any edits to an existing Custom Control are still possible but the freeze is approaching." "INFO"
}

# --- Step 1: Impact assessment — inventory every CA policy referencing a Custom Control grant ---
Write-Status "Scanning Conditional Access policies for Custom Control grant controls..."
try {
    $caPolicies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
} catch {
    Write-Status "Could not read Conditional Access policies: $($_.Exception.Message)" "ERROR"
    return
}

$customControlPolicies = $caPolicies | Where-Object { $_.GrantControls -and $_.GrantControls.CustomAuthenticationFactors }

if (-not $customControlPolicies -or @($customControlPolicies).Count -eq 0) {
    Write-Status "No Conditional Access policies reference a Custom Control. This tenant is NOT affected by this retirement." "OK"
    Write-Status "Audit complete — no further action needed on this topic." "OK"
    return
}

Write-Status "Found $(@($customControlPolicies).Count) Conditional Access polic(y/ies) referencing a Custom Control grant." "WARN"

# --- Step 2: Pull current External MFA configurations for migration-readiness cross-check ---
Write-Status "Reading Authentication Methods Policy for existing External MFA configurations..."
$externalMethods = @()
try {
    $authPolicy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
    $externalMethods = $authPolicy.authenticationMethodConfigurations |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' }
} catch {
    Write-Status "Could not read Authentication Methods Policy: $($_.Exception.Message)" "WARN"
}

$enabledExternalMethodCount = @($externalMethods | Where-Object { $_.state -eq "enabled" }).Count
Write-Status "Found $(@($externalMethods).Count) External MFA method configuration(s), $enabledExternalMethodCount enabled." "INFO"

# --- Step 3: Build the per-policy migration-readiness report ---
$report = foreach ($p in $customControlPolicies) {
    $daysUntilFreeze = [Math]::Round(($creationFreezeDate - $today).TotalDays)
    $daysUntilRetirement = [Math]::Round(($fullRetirementDate - $today).TotalDays)

    $riskFlags = @()
    if ($p.State -eq "enabled") { $riskFlags += "POLICY_ACTIVE" }
    if ($enabledExternalMethodCount -eq 0) { $riskFlags += "NO_EXTERNAL_MFA_METHOD_CONFIGURED_YET" }
    if ($today -ge $creationFreezeDate) { $riskFlags += "WITHIN_MODIFICATION_FREEZE" }
    if ($today -ge $fullRetirementDate) { $riskFlags += "PAST_FULL_RETIREMENT_GRANT_NO_LONGER_FUNCTIONS" }

    [PSCustomObject]@{
        PolicyName                 = $p.DisplayName
        PolicyId                   = $p.Id
        PolicyState                = $p.State
        CustomAuthFactors          = ($p.GrantControls.CustomAuthenticationFactors -join "; ")
        ExternalMFAMethodsConfigured = @($externalMethods).Count
        ExternalMFAMethodsEnabled    = $enabledExternalMethodCount
        DaysUntilCreationFreeze     = $daysUntilFreeze
        DaysUntilFullRetirement     = $daysUntilRetirement
        RiskFlags                  = ($riskFlags -join "; ")
        ProviderIdentification     = "NOT resolvable via Graph — check Entra admin center > Security > Conditional Access > Custom Controls (Preview)"
    }
}

$report | Export-Csv -Path (Join-Path $OutputPath "CACustomControls_MigrationReadiness_$timestamp.csv") -NoTypeInformation
Write-Status "Migration readiness report exported." "OK"

foreach ($row in $report) {
    if ($row.RiskFlags -match "PAST_FULL_RETIREMENT") {
        Write-Status "Policy '$($row.PolicyName)': PAST full retirement — Custom Control grant no longer functions. $($row.RiskFlags)" "ERROR"
    } elseif ($row.RiskFlags -match "NO_EXTERNAL_MFA_METHOD_CONFIGURED_YET" -and $row.PolicyState -eq "enabled") {
        Write-Status "Policy '$($row.PolicyName)': ACTIVE with no External MFA replacement configured yet — migration not started. $($row.RiskFlags)" "WARN"
    } else {
        Write-Status "Policy '$($row.PolicyName)': $($row.RiskFlags)" "INFO"
    }
}

# --- Step 4: Raw External MFA configuration dump for reference alongside the policy report ---
if (@($externalMethods).Count -gt 0) {
    $externalMethods | Select-Object id, displayName, state, appId,
        @{N="ClientId"; E={$_.openIdConnectSetting.clientId}},
        @{N="DiscoveryUrl"; E={$_.openIdConnectSetting.discoveryUrl}} |
        Export-Csv -Path (Join-Path $OutputPath "CACustomControls_ExternalMFAReference_$timestamp.csv") -NoTypeInformation
}

Write-Status "Audit complete. Reports written to: $OutputPath" "OK"
Write-Host ""
Write-Host "REMINDER: which third-party provider each flagged Custom Control points to is NOT" -ForegroundColor Yellow
Write-Host "resolvable via Graph — cross-reference the Entra admin center's Custom Controls (Preview)" -ForegroundColor Yellow
Write-Host "blade per policy before planning provider-specific migration work. See" -ForegroundColor Yellow
Write-Host "CustomControlsRetirement-A.md and EntraID/Troubleshooting/ExternalMFA-A.md for next steps." -ForegroundColor Yellow
