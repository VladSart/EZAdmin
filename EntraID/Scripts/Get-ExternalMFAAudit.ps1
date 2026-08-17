<#
.SYNOPSIS
    One-shot audit of Entra ID External MFA (External Authentication Methods) configuration health.

.DESCRIPTION
    Reads the tenant's Authentication Methods Policy and isolates every external MFA
    (externalAuthenticationMethodConfiguration) entry, then cross-checks the three most common
    real-world failure points documented in ExternalMFA-A.md / ExternalMFA-B.md:
      1. Method state (enabled/disabled) and whether admin consent to the provider's app was
         actually granted (service principal existence in the tenant) — the #1 "configured but
         stuck disabled" root cause, caused by a two-role split (Authentication Policy Administrator
         can save the method; only Privileged Role Administrator can grant consent).
      2. Any Conditional Access policy using an authentication strength grant control — external
         MFA cannot satisfy authentication strengths by design, so any such policy is flagged as a
         structural incompatibility risk for external-MFA-only users, not just a config gap.
      3. Reachability and issuer/discovery-URL consistency of each provider's live OIDC discovery
         endpoint (a best-effort, read-only external HTTP check).

    This script does NOT and CANNOT validate: individual sign-in acr/amr claim correctness (only
    visible per-sign-in in Sign-in logs), provider-side signing key rollover timing, or whether a
    specific user's OOBE failure is genuinely the documented Windows 10 limitation. Those require
    either sign-in log correlation or provider-side confirmation and are explicitly out of scope.

.PARAMETER IncludeDiscoveryCheck
    If set, performs a live HTTP GET against each provider's discovery URL to confirm reachability
    and issuer consistency. Off by default since it makes outbound calls to third-party endpoints.

.PARAMETER OutputPath
    Directory to write the CSV reports to. Defaults to the current directory.

.EXAMPLE
    .\Get-ExternalMFAAudit.ps1
    Audits method state, consent status, and CA policy authentication-strength conflicts only.

.EXAMPLE
    .\Get-ExternalMFAAudit.ps1 -IncludeDiscoveryCheck -OutputPath C:\Audits
    Also performs live discovery-endpoint checks for each configured provider.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Identity.SignIns modules
    Scopes:   Policy.Read.AuthenticationMethod, Application.Read.All, Policy.Read.All
    Safe/read-only: Yes — makes no configuration changes. -IncludeDiscoveryCheck makes outbound
    HTTP calls to third-party provider endpoints only, never to Microsoft Graph write operations.
#>

[CmdletBinding()]
param(
    [switch]$IncludeDiscoveryCheck,
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
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'Policy.Read.AuthenticationMethod','Application.Read.All','Policy.Read.All' first." "ERROR"
    return
}

$requiredScopes = @("Policy.Read.AuthenticationMethod")
$missing = $requiredScopes | Where-Object { $_ -notin $ctx.Scopes }
if ($missing) {
    Write-Status "Missing required scope(s): $($missing -join ', '). Re-run Connect-MgGraph with these scopes." "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmm'

# --- Step 1: Pull the Authentication Methods Policy and isolate external MFA configs ---
Write-Status "Reading Authentication Methods Policy..."
$authPolicy = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy" -Method GET
$externalMethods = $authPolicy.authenticationMethodConfigurations |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.externalAuthenticationMethodConfiguration' }

if (-not $externalMethods -or $externalMethods.Count -eq 0) {
    Write-Status "No external MFA methods configured in this tenant." "WARN"
    return
}

Write-Status "Found $($externalMethods.Count) external MFA method configuration(s)." "OK"

$methodReport = foreach ($m in $externalMethods) {
    $consentGranted = $false
    $spId = $null
    try {
        $sp = Get-MgServicePrincipal -Filter "appId eq '$($m.appId)'" -ErrorAction Stop
        if ($sp) { $consentGranted = $true; $spId = $sp.Id }
    } catch {
        $consentGranted = $false
    }

    $targetCount = 0
    if ($m.includeTargets) { $targetCount = @($m.includeTargets).Count }

    $riskFlags = @()
    if ($m.state -ne "enabled") { $riskFlags += "STATE_NOT_ENABLED" }
    if (-not $consentGranted) { $riskFlags += "ADMIN_CONSENT_MISSING" }
    if ($m.state -eq "enabled" -and -not $consentGranted) { $riskFlags += "ENABLED_WITHOUT_CONSENT_INCONSISTENT" }
    if ($targetCount -eq 0) { $riskFlags += "NO_INCLUDE_TARGETS_CONFIGURED" }

    [PSCustomObject]@{
        MethodId          = $m.id
        DisplayName       = $m.displayName
        State             = $m.state
        AppId             = $m.appId
        ClientId          = $m.openIdConnectSetting.clientId
        DiscoveryUrl      = $m.openIdConnectSetting.discoveryUrl
        AdminConsentGranted = $consentGranted
        ServicePrincipalId  = $spId
        IncludeTargetCount  = $targetCount
        ExcludeTargetCount  = if ($m.excludeTargets) { @($m.excludeTargets).Count } else { 0 }
        RiskFlags           = ($riskFlags -join "; ")
    }
}

$methodReport | Export-Csv -Path (Join-Path $OutputPath "ExternalMFA_Methods_$timestamp.csv") -NoTypeInformation
Write-Status "Method configuration + consent report exported." "OK"

foreach ($row in $methodReport) {
    if ($row.RiskFlags) {
        Write-Status "Method '$($row.DisplayName)': $($row.RiskFlags)" "WARN"
    } else {
        Write-Status "Method '$($row.DisplayName)': healthy (enabled, consented, targeted)." "OK"
    }
}

# --- Step 2: Cross-check Conditional Access policies for authentication-strength incompatibility ---
Write-Status "Scanning Conditional Access policies for authentication strength grant controls..."
try {
    $caPolicies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    $strengthPolicies = foreach ($p in $caPolicies) {
        $gc = $p.GrantControls
        $usesStrength = $false
        if ($gc -and $gc.AuthenticationStrength) { $usesStrength = $true }
        if ($usesStrength) {
            [PSCustomObject]@{
                PolicyName        = $p.DisplayName
                PolicyState       = $p.State
                AuthStrengthId    = $gc.AuthenticationStrength.Id
                Note              = "External MFA CANNOT satisfy this policy by design — verify no external-MFA-only users fall in scope."
            }
        }
    }
    if ($strengthPolicies) {
        $strengthPolicies | Export-Csv -Path (Join-Path $OutputPath "ExternalMFA_CAStrengthConflicts_$timestamp.csv") -NoTypeInformation
        Write-Status "$($strengthPolicies.Count) Conditional Access polic(ies) use an authentication strength grant control — exported for manual scope cross-check." "WARN"
    } else {
        Write-Status "No Conditional Access policies use an authentication strength grant control." "OK"
    }
} catch {
    Write-Status "Could not read Conditional Access policies (requires Policy.Read.All): $($_.Exception.Message)" "WARN"
}

# --- Step 3 (optional): Live discovery endpoint reachability check ---
if ($IncludeDiscoveryCheck) {
    Write-Status "Performing live discovery endpoint checks (outbound calls to third-party providers)..."
    $discoveryReport = foreach ($m in $externalMethods) {
        $url = $m.openIdConnectSetting.discoveryUrl
        $result = [ordered]@{
            DisplayName   = $m.displayName
            DiscoveryUrl  = $url
            Reachable     = $false
            IssuerMatches = $false
            Issuer        = $null
            Error         = $null
        }
        try {
            $doc = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 10
            $result.Reachable = $true
            $result.Issuer = $doc.issuer
            # Best-effort issuer/discovery-URL host consistency check (not a full RFC-compliant validation)
            $discoveryHost = ([Uri]$url).Host
            $issuerHost = try { ([Uri]$doc.issuer).Host } catch { $null }
            $result.IssuerMatches = ($discoveryHost -eq $issuerHost)
        } catch {
            $result.Error = $_.Exception.Message
        }
        [PSCustomObject]$result
    }
    $discoveryReport | Export-Csv -Path (Join-Path $OutputPath "ExternalMFA_DiscoveryCheck_$timestamp.csv") -NoTypeInformation
    foreach ($d in $discoveryReport) {
        if (-not $d.Reachable) {
            Write-Status "Provider '$($d.DisplayName)' discovery endpoint unreachable: $($d.Error)" "ERROR"
        } elseif (-not $d.IssuerMatches) {
            Write-Status "Provider '$($d.DisplayName)': issuer host does not match discovery URL host — investigate before assuming a signature error is tenant-side." "WARN"
        } else {
            Write-Status "Provider '$($d.DisplayName)' discovery endpoint healthy." "OK"
        }
    }
}

Write-Status "Audit complete. Reports written to: $OutputPath" "OK"
Write-Host ""
Write-Host "REMINDER: acr/amr claim validation failures for specific failed sign-ins are only" -ForegroundColor Yellow
Write-Host "visible in Entra ID Sign-in logs (filter by Correlation ID) and are not retrievable" -ForegroundColor Yellow
Write-Host "via Graph policy reads — cross-reference this report with sign-in logs for a full picture." -ForegroundColor Yellow
