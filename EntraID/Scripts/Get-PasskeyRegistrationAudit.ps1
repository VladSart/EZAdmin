<#
.SYNOPSIS
    Audits Passkey (FIDO2) registration coverage, tenant policy configuration, and common
    bootstrap/lockout risk conditions across an Entra ID tenant.

.DESCRIPTION
    Connects to Microsoft Graph and reports on three layers described in
    EntraID/Troubleshooting/Passkeys-A.md and Passkeys-B.md:

    1. Tenant-level Passkey (FIDO2) policy state — enabled/disabled, self-service registration
       allowed, attestation enforcement (read via the v1.0 authenticationMethodConfigurations/Fido2
       endpoint; profile-level detail beyond the base policy is admin-center-only as of this
       writing and is not fully exposed via stable Graph endpoints).

    2. Per-user registered passkey (FIDO2) method inventory — AAGUID, attestation level, and a
       recognised-vendor lookup against a small built-in table (Microsoft Authenticator AAGUIDs)
       so unrecognised/unexpected AAGUIDs are flagged for review rather than silently accepted.

    3. Conditional Access bootstrap-loop risk — flags any enabled CA policy that requires a
       phishing-resistant-style authentication strength across "All resources" without excluding
       the "Register security information" user action, which is the root cause of the most common
       real-world passkey rollout support call (users locked out of registering their first
       passkey). Also flags whether Temporary Access Pass is configured for one-time use only,
       since a reusable TAP is rejected by any authentication strength requiring one-time-use TAP.

    Exports a CSV per user plus a console risk summary. Read-only — makes no policy, CA, or
    authentication-method changes.

    Does NOT cover:
    - Actually building or modifying the TAP bootstrap Conditional Access policies — see
      Passkeys-A.md Playbook 2 for the guided build
    - Windows Hello for Business coverage — see Get-WHfBRegistrationStatus.ps1
    - Passkey profile CRUD (attestation/type/AAGUID settings per profile) — admin-center only

.PARAMETER UserPrincipalName
    One or more UPNs to audit. If omitted, use -All to audit every enabled user.

.PARAMETER All
    Audit all enabled users in the tenant instead of a specific list.

.PARAMETER Top
    Maximum number of users to process when -All is used. Default: 300.

.PARAMETER KnownAaguids
    Optional hashtable of additional AAGUID => vendor-name pairs to treat as recognised,
    beyond the built-in Microsoft Authenticator entries. Merge your organization's approved
    security key / password-manager AAGUIDs here to reduce false-positive "unrecognised" flags.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\Passkey-Registration-Audit-<timestamp>.csv

.EXAMPLE
    .\Get-PasskeyRegistrationAudit.ps1 -UserPrincipalName alice@contoso.com,bob@contoso.com

.EXAMPLE
    .\Get-PasskeyRegistrationAudit.ps1 -All -Top 500

.EXAMPLE
    .\Get-PasskeyRegistrationAudit.ps1 -All -KnownAaguids @{ "d41f5a69-b817-4144-a13c-9ebd6d9254d6" = "Bitwarden" }

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: Policy.Read.All, UserAuthenticationMethod.Read.All, User.Read.All,
                   Policy.Read.ConditionalAccess (or equivalent), AuditLog.Read.All (optional,
                   for future extension — not required by the checks in this version)
    Run As: An account with Reports Reader, Global Reader, Security Reader, or Authentication
            Policy Administrator (read) role — does not require write permissions
    Safe: Read-only — no Fido2 policy, Conditional Access policy, TAP policy, or user
          authentication methods are changed
    Cross-references: EntraID/Troubleshooting/Passkeys-A.md (Validation Steps, Playbooks 1-3),
                       EntraID/Troubleshooting/Passkeys-B.md (Triage, Fix 1-5)
#>

[CmdletBinding(DefaultParameterSetName = "ByUser")]
param(
    [Parameter(ParameterSetName = "ByUser")]
    [string[]]$UserPrincipalName,

    [Parameter(ParameterSetName = "All")]
    [switch]$All,

    [Parameter(ParameterSetName = "All")]
    [int]$Top = 300,

    [hashtable]$KnownAaguids = @{},

    [string]$OutputPath = ".\Passkey-Registration-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# Built-in recognised AAGUIDs (Microsoft Authenticator device-bound passkeys). Merge with
# any org-supplied list via -KnownAaguids.
$recognisedAaguids = @{
    "de1e552d-db1d-4423-a619-566b625cdc84" = "Microsoft Authenticator (Android)"
    "90a3ccdf-635c-4729-a248-9b709135078f" = "Microsoft Authenticator (iOS)"
}
foreach ($key in $KnownAaguids.Keys) { $recognisedAaguids[$key] = $KnownAaguids[$key] }

# ─── Connect ───
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","User.Read.All","Policy.Read.ConditionalAccess" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── Layer 1: Tenant Fido2 policy state ───
Write-Status "Checking tenant Passkey (FIDO2) policy state..." "INFO"

$fido2Policy = $null
try {
    $fido2Policy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2" -ErrorAction Stop
    $policyState = $fido2Policy.state
    $selfService = $fido2Policy.isSelfServiceRegistrationAllowed
    $attestationEnforced = $fido2Policy.isAttestationEnforced

    $flag = if ($policyState -ne "enabled") { "ERROR" } else { "OK" }
    Write-Status "Fido2 policy state: $policyState | Self-service: $selfService | Attestation enforced: $attestationEnforced" $flag
} catch {
    Write-Status "Failed to read Fido2 policy: $($_.Exception.Message)" "ERROR"
}

# ─── Layer 1b: TAP one-time-use setting (bootstrap prerequisite) ───
$tapOneTimeUse = $null
try {
    $tapPolicy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass" -ErrorAction Stop
    $tapOneTimeUse = $tapPolicy.isUsableOnce
    $flag = if ($tapOneTimeUse -eq $false) { "WARN" } else { "OK" }
    Write-Status "TAP one-time-use only: $tapOneTimeUse (if False, TAP-based passkey bootstrap auth strengths will reject the TAP)" $flag
} catch {
    Write-Status "Failed to read Temporary Access Pass policy: $($_.Exception.Message)" "WARN"
}

# ─── Layer 1c: CA bootstrap-loop risk scan ───
Write-Status "Scanning Conditional Access policies for passkey registration lockout risk..." "INFO"

$caLockoutRisk = $false
$riskyPolicies = @()
try {
    $caUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"
    $caPolicies = (Invoke-MgGraphRequest -Method GET -Uri $caUri -ErrorAction Stop).value

    foreach ($pol in $caPolicies) {
        if ($pol.state -ne "enabled") { continue }
        $strengthName = $pol.grantControls.authenticationStrength.displayName
        $includeActions = $pol.conditions.applications.includeUserActions
        $excludeActions = $pol.conditions.applications.excludeUserActions
        $includesAllResources = $pol.conditions.applications.includeApplications -contains "All"

        $requiresPhishResistant = $strengthName -match "Phishing"
        $targetsRegistration = $includeActions -contains "urn:user:registersecurityinfo"
        $excludesRegistration = $excludeActions -contains "urn:user:registersecurityinfo"

        if ($requiresPhishResistant -and $includesAllResources -and -not $excludesRegistration -and -not $targetsRegistration) {
            $caLockoutRisk = $true
            $riskyPolicies += [PSCustomObject]@{
                PolicyName = $pol.displayName
                Strength   = $strengthName
                Risk       = "Requires phishing-resistant MFA on All resources WITHOUT excluding 'Register security information' — users with no passkey yet may be locked out of onboarding one"
            }
        }
    }

    if ($caLockoutRisk) {
        Write-Status "$($riskyPolicies.Count) Conditional Access polic(ies) show passkey bootstrap lockout risk — see Passkeys-B.md Fix 2 / Passkeys-A.md Playbook 2" "ERROR"
        $riskyPolicies | Format-Table -AutoSize
    } else {
        Write-Status "No obvious CA bootstrap-lockout pattern detected (heuristic check only — always test with a pilot account before wide rollout)" "OK"
    }
} catch {
    Write-Status "Failed to scan Conditional Access policies: $($_.Exception.Message)" "WARN"
}

# ─── Layer 2: Build target user list ───
$targetUsers = @()
if ($PSCmdlet.ParameterSetName -eq "All") {
    Write-Status "Fetching up to $Top enabled users..." "INFO"
    $targetUsers = Get-MgUser -Filter "accountEnabled eq true" -Top $Top -Property Id,UserPrincipalName,DisplayName -ErrorAction Stop
} else {
    foreach ($upn in $UserPrincipalName) {
        try {
            $targetUsers += Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName -ErrorAction Stop
        } catch {
            Write-Status "User not found: $upn" "ERROR"
        }
    }
}

if (-not $targetUsers -or $targetUsers.Count -eq 0) {
    Write-Status "No users to process. Specify -UserPrincipalName or -All." "ERROR"
    return
}

# ─── Layer 2: Per-user passkey inventory ───
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($user in $targetUsers) {
    $upn = $user.UserPrincipalName
    Write-Status "Processing: $upn" "INFO"

    $result = [PSCustomObject]@{
        UserPrincipalName   = $upn
        DisplayName         = $user.DisplayName
        PasskeyRegistered   = $false
        PasskeyCount        = 0
        Vendors             = "None"
        UnrecognisedAAGUIDs = "None"
        AttestedCount       = 0
        UnattestedCount     = 0
        RiskFlag            = "OK"
        Errors              = ""
    }

    try {
        $methods = Get-MgUserAuthenticationFido2Method -UserId $user.Id -ErrorAction Stop
        $result.PasskeyCount      = ($methods | Measure-Object).Count
        $result.PasskeyRegistered = $result.PasskeyCount -gt 0

        if ($methods) {
            $vendorNames = foreach ($m in $methods) {
                if ($recognisedAaguids.ContainsKey($m.AaGuid)) { $recognisedAaguids[$m.AaGuid] } else { "Unknown ($($m.AaGuid))" }
            }
            $result.Vendors = ($vendorNames | Select-Object -Unique) -join " | "

            $unrecognised = $methods | Where-Object { -not $recognisedAaguids.ContainsKey($_.AaGuid) }
            if ($unrecognised) {
                $result.UnrecognisedAAGUIDs = ($unrecognised | Select-Object -ExpandProperty AaGuid -Unique) -join " | "
            }

            $result.AttestedCount   = ($methods | Where-Object { $_.AttestationLevel -eq "attested" } | Measure-Object).Count
            $result.UnattestedCount = $result.PasskeyCount - $result.AttestedCount
        }
    } catch {
        $result.Errors += "Fido2 method lookup failed: $($_.Exception.Message); "
    }

    if (-not $result.PasskeyRegistered) {
        $result.RiskFlag = "NOT_PROVISIONED"
    } elseif ($result.UnrecognisedAAGUIDs -ne "None") {
        $result.RiskFlag = "UNRECOGNISED_AAGUID"
    }

    $allResults.Add($result)

    $flag = switch ($result.RiskFlag) {
        "NOT_PROVISIONED"      { "WARN" }
        "UNRECOGNISED_AAGUID"  { "WARN" }
        default                 { "OK" }
    }
    Write-Status "  Passkeys: $($result.PasskeyCount) | Vendors: $($result.Vendors) | Risk: $($result.RiskFlag)" $flag
}

# ─── Export ───
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== Passkey (FIDO2) Registration Audit Summary ===" -ForegroundColor Cyan
Write-Host "Tenant Fido2 policy state   : $($fido2Policy.state)"
Write-Host "Self-service registration  : $($fido2Policy.isSelfServiceRegistrationAllowed)"
Write-Host "Attestation enforced       : $($fido2Policy.isAttestationEnforced)"
Write-Host "TAP one-time-use only      : $tapOneTimeUse"
Write-Host "CA bootstrap lockout risk  : $caLockoutRisk"
Write-Host ""
$allResults | Format-Table UserPrincipalName, PasskeyRegistered, PasskeyCount, Vendors, RiskFlag -AutoSize

$notProvisioned = ($allResults | Where-Object { $_.RiskFlag -eq "NOT_PROVISIONED" }).Count
$unrecognised   = ($allResults | Where-Object { $_.RiskFlag -eq "UNRECOGNISED_AAGUID" }).Count
if ($notProvisioned -gt 0) { Write-Status "$notProvisioned user(s) have no passkey (FIDO2) registered" "WARN" }
if ($unrecognised -gt 0) { Write-Status "$unrecognised user(s) have passkeys from an unrecognised AAGUID/vendor — review against approved provider list" "WARN" }
if ($notProvisioned -eq 0 -and $unrecognised -eq 0) { Write-Status "All processed users have recognised passkeys registered" "OK" }
