<#
.SYNOPSIS
    Audits Entra ID Certificate-Based Authentication (CBA) configuration and per-user
    certificate-to-user binding readiness ahead of a rollout or as escalation evidence.

.DESCRIPTION
    Connects to Microsoft Graph and reports, read-only:
    - Whether the X509Certificate authentication method policy is enabled and its scope
    - Every trusted certificate authority in the tenant's certificateAuthorities collection,
      flagging whether each is marked as a root authority and whether a CRL distribution
      point is present at all (does not test reachability — that requires network access
      from wherever this script runs, see EntraID/Troubleshooting/CBA-A.md Validation Step 3)
    - The configured certificate-to-user binding priority order and type (high-affinity via
      certificateUserIds vs. low-affinity via UPN/RFC822Name), flagging low-affinity bindings
      as a WARN-level finding per current Microsoft guidance
    - For each target user: whether their certificateUserIds attribute is populated (required
      for high-affinity binding to resolve) and their UPN (required for low-affinity binding)

    This answers the two questions a CBA rollout or escalation always needs first: "is the
    trust/binding configuration itself sound" and "which specific users are missing the
    attribute their certificate would need to bind against."

    Exports results to CSV and prints a colour-coded console summary. Read-only — makes no
    changes to CA trust list, binding policy, or user attributes.

    Does NOT cover:
    - Certificate chain validation against a specific issued certificate (requires the actual
      cert file — see CBA-A.md Validation Step 2 for manual chain comparison)
    - CRL/CDP network reachability testing (see CBA-A.md Validation Step 3, certutil -URL)
    - Client-side smart card/middleware diagnostics (see CBA-B.md Fix 5)

.PARAMETER UserPrincipalName
    One or more UPNs to check binding-attribute readiness for. If omitted, use -All.

.PARAMETER All
    Check binding-attribute readiness for all enabled users in the tenant instead of a
    specific list.

.PARAMETER Top
    Maximum number of users to process when -All is used. Default: 300.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\CBA-Configuration-Audit-<timestamp>.csv

.EXAMPLE
    .\Get-CBAConfigurationAudit.ps1 -UserPrincipalName alice@contoso.com,bob@contoso.com

.EXAMPLE
    .\Get-CBAConfigurationAudit.ps1 -All -Top 500

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: Policy.Read.All, User.Read.All, Directory.Read.All
    Run As: An account with Global Reader, Security Reader, or Authentication Policy
            Administrator (read) role — does not require write permissions
    Safe: Read-only — no policy, CA trust list, or user attribute changes are made
    Cross-references: EntraID/Troubleshooting/CBA-A.md (Validation Steps, Playbook 1, Playbook 4),
                       EntraID/Troubleshooting/CBA-B.md (Fix 1-4)
#>

[CmdletBinding(DefaultParameterSetName = "ByUser")]
param(
    [Parameter(ParameterSetName = "ByUser")]
    [string[]]$UserPrincipalName,

    [Parameter(ParameterSetName = "All")]
    [switch]$All,

    [Parameter(ParameterSetName = "All")]
    [int]$Top = 300,

    [string]$OutputPath = ".\CBA-Configuration-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ─── Connect ───
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "Policy.Read.All","User.Read.All","Directory.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── CBA policy state ───
Write-Status "Checking X509Certificate authentication method policy state..." "INFO"
$cbaState = "Unknown"
$bindingConfig = $null
try {
    $cbaPolicy = Get-MgPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration -AuthenticationMethodConfigurationId "X509Certificate" -EA Stop
    $cbaState = $cbaPolicy.State
    $bindingConfig = $cbaPolicy.AdditionalProperties.certificateUserBindings
    Write-Status "CBA policy state: $cbaState" $(if ($cbaState -eq "enabled") { "OK" } else { "WARN" })
} catch {
    Write-Status "Could not read CBA policy: $($_.Exception.Message)" "ERROR"
}

if ($bindingConfig) {
    Write-Host "`n=== Certificate-to-User Binding Priority ===" -ForegroundColor Cyan
    $bindingIndex = 0
    foreach ($binding in $bindingConfig) {
        $bindingIndex++
        $isHighAffinity = $binding.userProperty -eq "certificateUserIds"
        $affinity = if ($isHighAffinity) { "HIGH" } else { "LOW (legacy — spoofable)" }
        $flag = if ($isHighAffinity) { "OK" } else { "WARN" }
        Write-Status "Priority $bindingIndex : $($binding.x509CertificateField) -> $($binding.userProperty) [$affinity]" $flag
    }
} else {
    Write-Status "No certificate-to-user binding configuration retrieved." "WARN"
}

# ─── Trusted certificate authorities ───
Write-Status "`nEnumerating trusted certificate authorities..." "INFO"
$caResults = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $cas = Get-MgDirectoryCertificateAuthority -EA Stop
    foreach ($ca in $cas) {
        $hasCdp = -not [string]::IsNullOrWhiteSpace($ca.CrlDistributionPoint)
        $caResults.Add([PSCustomObject]@{
            Certificate         = $ca.Certificate
            IsRootAuthority     = $ca.IsRootAuthority
            HasCrlDistribution  = $hasCdp
        })
        $flag = if ($hasCdp) { "OK" } else { "WARN" }
        Write-Status "CA (Root=$($ca.IsRootAuthority)) — CRL configured: $hasCdp" $flag
    }
    if ($caResults.Count -eq 0) {
        Write-Status "No trusted CAs found — CBA cannot validate any certificate chain until at least one is uploaded." "ERROR"
    }
} catch {
    Write-Status "Could not enumerate certificate authorities: $($_.Exception.Message)" "ERROR"
}

# ─── Build target user list ───
$targetUsers = @()
if ($PSCmdlet.ParameterSetName -eq "All") {
    Write-Status "`nFetching up to $Top enabled users..." "INFO"
    $targetUsers = Get-MgUser -Filter "accountEnabled eq true" -Top $Top -Property Id,UserPrincipalName,DisplayName,OnPremisesUserPrincipalName -EA Stop
} elseif ($UserPrincipalName) {
    foreach ($upn in $UserPrincipalName) {
        try {
            $targetUsers += Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,OnPremisesUserPrincipalName -EA Stop
        } catch {
            Write-Status "User not found: $upn" "ERROR"
        }
    }
}

$userResults = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($targetUsers -and $targetUsers.Count -gt 0) {
    Write-Status "`nChecking per-user binding attribute readiness..." "INFO"
    foreach ($user in $targetUsers) {
        $certUserIds = $null
        try {
            $full = Get-MgUser -UserId $user.Id -Property certificateUserIds -EA Stop
            $certUserIds = $full.AdditionalProperties.certificateUserIds
        } catch {
            # Non-fatal — leave null, flagged below
        }

        $hasHighAffinity = $certUserIds -and ($certUserIds | Measure-Object).Count -gt 0
        $hasUpn          = -not [string]::IsNullOrWhiteSpace($user.UserPrincipalName)

        $readiness = if ($hasHighAffinity) { "READY_HIGH_AFFINITY" }
                     elseif ($hasUpn) { "READY_LOW_AFFINITY_ONLY" }
                     else { "NOT_READY" }

        $result = [PSCustomObject]@{
            UserPrincipalName        = $user.UserPrincipalName
            DisplayName              = $user.DisplayName
            CertificateUserIdsCount  = if ($certUserIds) { ($certUserIds | Measure-Object).Count } else { 0 }
            HasUpnForLowAffinity     = $hasUpn
            BindingReadiness         = $readiness
        }
        $userResults.Add($result)

        $flag = switch ($readiness) {
            "READY_HIGH_AFFINITY"      { "OK" }
            "READY_LOW_AFFINITY_ONLY"  { "WARN" }
            default                    { "ERROR" }
        }
        Write-Status "  $($user.UserPrincipalName): $readiness" $flag
    }
} else {
    Write-Status "`nNo target users specified — skipping per-user binding readiness check. Use -UserPrincipalName or -All." "WARN"
}

# ─── Export ───
if ($userResults.Count -gt 0) {
    $outputDir = Split-Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $userResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Status "`nPer-user results exported to: $OutputPath" "OK"
}

Write-Host "`n=== CBA Configuration Summary ===" -ForegroundColor Cyan
Write-Host "Policy state       : $cbaState"
Write-Host "Trusted CA count   : $($caResults.Count)"
Write-Host "CAs missing CRL    : $(($caResults | Where-Object { -not $_.HasCrlDistribution }).Count)"
if ($userResults.Count -gt 0) {
    $notReady = ($userResults | Where-Object { $_.BindingReadiness -eq "NOT_READY" }).Count
    $lowOnly  = ($userResults | Where-Object { $_.BindingReadiness -eq "READY_LOW_AFFINITY_ONLY" }).Count
    Write-Host "Users NOT_READY    : $notReady"
    Write-Host "Users low-affinity only (no certificateUserIds set) : $lowOnly"
    if ($notReady -gt 0) { Write-Status "$notReady user(s) have no binding attribute populated at all — CBA sign-in will fail to resolve an account for them." "ERROR" }
    if ($lowOnly -gt 0)  { Write-Status "$lowOnly user(s) can only bind via legacy low-affinity matching — consider populating certificateUserIds per CBA-A.md Playbook 2." "WARN" }
}
if ($cbaState -ne "enabled") { Write-Status "CBA policy is not enabled — no user in scope will see a certificate prompt regardless of the above." "ERROR" }
