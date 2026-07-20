<#
.SYNOPSIS
    Audits Conditional Access Authentication Strength policies, the CA policies that reference them,
    and tenant-wide user registration coverage for the methods those strengths require.

.DESCRIPTION
    Read-only report covering:
      - All authentication strength policies (built-in + custom) and their allowed combinations
      - Every CA policy that uses an authentication-strength grant control, and its state
      - Users who lack a qualifying method for phishing-resistant / passwordless strengths
      - Federated domains and their federatedIdpMfaBehavior trust setting
      - Custom strengths with suspicious/empty combination lists (design smell)
    Does not modify any policy, strength, or user object. Intended to be run before enabling
    enforcement on a new/edited authentication-strength CA policy, or when triaging a ticket
    where users report being unexpectedly blocked by a strength requirement.

.PARAMETER OutputPath
    Folder to write the CSV reports to. Defaults to the current directory.

.PARAMETER IncludeAllUsers
    If specified, includes the full per-user registration coverage table in the CSV output
    (can be large in bigger tenants). Without this switch, only the gap population is exported.

.EXAMPLE
    .\Get-AuthStrengthCoverageAudit.ps1 -OutputPath C:\Temp\Reports

.EXAMPLE
    .\Get-AuthStrengthCoverageAudit.ps1 -IncludeAllUsers

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports modules
    Scopes:   Policy.Read.All, UserAuthenticationMethod.Read.All, Reports.Read.All, Domain.Read.All
    Safe to run in production — read-only Graph calls only.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [switch]$IncludeAllUsers
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
    "Microsoft.Graph.Identity.SignIns",
    "Microsoft.Graph.Reports",
    "Microsoft.Graph.Identity.DirectoryManagement"
)
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Status "Module $m not found. Install with: Install-Module $m -Scope CurrentUser" "WARN"
    }
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","Reports.Read.All","Domain.Read.All" -NoWelcome

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"

# ---------------------------------------------------------------------------
# Detect — Authentication Strength Policies
# ---------------------------------------------------------------------------
Write-Status "Pulling authentication strength policies..."
$strengths = Get-MgPolicyAuthenticationStrengthPolicy -All

$strengthReport = foreach ($s in $strengths) {
    $comboCount = ($s.AllowedCombinations | Measure-Object).Count
    [PSCustomObject]@{
        Name                = $s.DisplayName
        Id                  = $s.Id
        PolicyType          = $s.PolicyType
        CombinationCount    = $comboCount
        AllowedCombinations = ($s.AllowedCombinations -join "; ")
        DesignFlag          = if ($comboCount -eq 0) { "EMPTY - policy can never be satisfied" }
                               elseif ($s.PolicyType -eq "custom" -and ($s.AllowedCombinations -contains "temporaryAccessPassMultiUse")) { "WARN - TAP included as standing credential" }
                               else { "" }
    }
}
$strengthReport | Export-Csv -Path (Join-Path $OutputPath "AuthStrengthPolicies-$timestamp.csv") -NoTypeInformation

$emptyStrengths = $strengthReport | Where-Object { $_.DesignFlag -like "EMPTY*" }
if ($emptyStrengths) {
    Write-Status "$($emptyStrengths.Count) strength policy(ies) have zero allowed combinations — cannot ever be satisfied" "WARN"
}

# ---------------------------------------------------------------------------
# Detect — CA Policies Referencing Authentication Strength
# ---------------------------------------------------------------------------
Write-Status "Pulling Conditional Access policies that reference authentication strength..."
$allCaPolicies = Get-MgIdentityConditionalAccessPolicy -All
$strengthPolicies = $allCaPolicies | Where-Object { $_.GrantControls.AuthenticationStrength }

$caReport = foreach ($p in $strengthPolicies) {
    $strengthId = $p.GrantControls.AuthenticationStrength.Id
    $strengthName = ($strengths | Where-Object Id -eq $strengthId).DisplayName
    [PSCustomObject]@{
        PolicyName     = $p.DisplayName
        PolicyId       = $p.Id
        State          = $p.State
        StrengthName   = $strengthName
        StrengthId     = $strengthId
        IncludedUsers  = ($p.Conditions.Users.IncludeUsers -join ", ")
        ExcludedGroups = ($p.Conditions.Users.ExcludeGroups -join ", ")
    }
}
$caReport | Export-Csv -Path (Join-Path $OutputPath "CAPoliciesUsingAuthStrength-$timestamp.csv") -NoTypeInformation

$enforcedNoExclusions = $caReport | Where-Object { $_.State -eq "enabled" -and [string]::IsNullOrWhiteSpace($_.ExcludedGroups) }
if ($enforcedNoExclusions) {
    Write-Status "$($enforcedNoExclusions.Count) enforced auth-strength polic(ies) have NO exclusion group — confirm break-glass accounts are protected" "WARN"
}

# ---------------------------------------------------------------------------
# Detect — Registration Coverage Gaps
# ---------------------------------------------------------------------------
Write-Status "Pulling tenant-wide authentication method registration details (this can take a while in large tenants)..."
$registrations = Get-MgReportAuthenticationMethodUserRegistrationDetail -All

$phishResistantPattern = 'fido2|windowsHelloForBusiness|x509CertificateMultiFactor'

$gapUsers = $registrations | Where-Object {
    -not ($_.MethodsRegistered -join "," -match $phishResistantPattern)
}

$gapReport = $gapUsers | Select-Object UserPrincipalName, IsMfaRegistered,
    @{N = "MethodsRegistered"; E = { $_.MethodsRegistered -join ", " } }

$gapReport | Export-Csv -Path (Join-Path $OutputPath "PhishResistantCoverageGaps-$timestamp.csv") -NoTypeInformation
Write-Status "$($gapReport.Count) of $($registrations.Count) users lack a phishing-resistant-capable method" "WARN"

if ($IncludeAllUsers) {
    $registrations | Select-Object UserPrincipalName, IsMfaRegistered,
        @{N = "MethodsRegistered"; E = { $_.MethodsRegistered -join ", " } } |
        Export-Csv -Path (Join-Path $OutputPath "AllUserRegistrationCoverage-$timestamp.csv") -NoTypeInformation
}

# ---------------------------------------------------------------------------
# Detect — Federated Domain MFA Trust
# ---------------------------------------------------------------------------
Write-Status "Checking federated domains for MFA trust configuration..."
$federatedDomains = Get-MgDomain -All | Where-Object { $_.AuthenticationType -eq "Federated" }

$fedReport = foreach ($d in $federatedDomains) {
    try {
        $fedConfig = Get-MgDomainFederationConfiguration -DomainId $d.Id -ErrorAction Stop
        [PSCustomObject]@{
            Domain               = $d.Id
            FederatedIdpMfaBehavior = $fedConfig.FederatedIdpMfaBehavior
            TrustsFederatedMfa   = if ($fedConfig.FederatedIdpMfaBehavior -eq "acceptIfMfaDoneByFederatedIdp") { "Yes" } else { "No" }
        }
    } catch {
        [PSCustomObject]@{
            Domain               = $d.Id
            FederatedIdpMfaBehavior = "ERROR retrieving config"
            TrustsFederatedMfa   = "Unknown"
        }
    }
}
$fedReport | Export-Csv -Path (Join-Path $OutputPath "FederatedDomainMfaTrust-$timestamp.csv") -NoTypeInformation

# ---------------------------------------------------------------------------
# Report — Summary
# ---------------------------------------------------------------------------
Write-Status "=== Summary ===" "OK"
Write-Status "Authentication strength policies found: $($strengths.Count)"
Write-Status "CA policies referencing authentication strength: $($caReport.Count)"
Write-Status "Users without phishing-resistant-capable method: $($gapReport.Count) / $($registrations.Count)"
Write-Status "Federated domains checked: $($fedReport.Count)"
Write-Status "Reports written to: $(Resolve-Path $OutputPath)" "OK"

Disconnect-MgGraph | Out-Null
