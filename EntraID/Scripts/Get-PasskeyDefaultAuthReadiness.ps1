<#
.SYNOPSIS
    Audits a tenant's readiness for Microsoft's Sept 1, 2026 passkey-default-authentication
    rollout and the Feb 1, 2027 SMS/Voice retirement enforcement.

.DESCRIPTION
    Read-only readiness check for the Entra ID SMS/Voice retirement announced for public
    cloud tenants (see EntraID/Troubleshooting/PasskeyDefaultAuth-A.md / -B.md for the full
    runbook). Reports, tenant-wide:

    - Whether the tenant has set the temporary opt-out (optOutSettings.passkeyDynamicMigration)
    - Current SMS / Voice authentication method policy state
    - Current Registration Campaign state and target scope
    - Per-user: whether they are enabled for SMS or Voice, whether they already have a
      phishing-resistant method registered (passkey/FIDO2/WHfB), and whether they appear to
      have an explicitly-registered SSPR-eligible method (relevant to the Sept 7, 2026 SSPR
      tightening)
    - A summary risk flag per user: NO_ACTION_NEEDED, WILL_BE_NUDGED (Phase 1),
      AT_RISK_FEB2027 (only method is SMS/Voice — will hit the blocking prompt if untouched)

    Does NOT change any policy, enroll any user in passkeys, or modify SMS/Voice settings —
    this is an audit/reporting script only. Use the Fix/Playbook sections in
    PasskeyDefaultAuth-B.md / -A.md to actually opt out or migrate users.

    Does not replace Microsoft's own exposure analyzer
    (https://github.com/microsoft/entra-sms-voice-usage-analyzer) for the authoritative legacy
    per-user MFA settings surface — this script covers the modern Authentication Methods Policy
    (AMP) surface via Microsoft Graph and is intended as a fast, no-extra-tooling first pass.

.PARAMETER UserPrincipalName
    One or more UPNs to audit. If omitted, use -All to audit every enabled user.

.PARAMETER All
    Audit all enabled users in the tenant instead of a specific list.

.PARAMETER Top
    Maximum number of users to process when -All is used. Default: 500.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\PasskeyDefaultAuth-Readiness-<timestamp>.csv

.EXAMPLE
    .\Get-PasskeyDefaultAuthReadiness.ps1 -All -Top 1000

.EXAMPLE
    .\Get-PasskeyDefaultAuthReadiness.ps1 -UserPrincipalName alice@contoso.com,bob@contoso.com

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: Policy.Read.All, UserAuthenticationMethod.Read.All, User.Read.All
    Run As: Global Reader, Security Reader, or Authentication Policy Administrator (read) —
            does not require write permissions
    Safe: Read-only — makes no policy or auth-method changes
    Cross-references: EntraID/Troubleshooting/PasskeyDefaultAuth-A.md,
                       EntraID/Troubleshooting/PasskeyDefaultAuth-B.md
#>

[CmdletBinding(DefaultParameterSetName = "ByUser")]
param(
    [Parameter(ParameterSetName = "ByUser")]
    [string[]]$UserPrincipalName,

    [Parameter(ParameterSetName = "All")]
    [switch]$All,

    [Parameter(ParameterSetName = "All")]
    [int]$Top = 500,

    [string]$OutputPath = ".\PasskeyDefaultAuth-Readiness-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

$phishingResistantTypes = @(
    "#microsoft.graph.fido2AuthenticationMethod",
    "#microsoft.graph.windowsHelloForBusinessAuthenticationMethod",
    "#microsoft.graph.platformCredentialAuthenticationMethod"
)
$smsVoiceTypes = @(
    "#microsoft.graph.phoneAuthenticationMethod"
)

# ─── Connect ───
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "Policy.Read.All","UserAuthenticationMethod.Read.All","User.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── Tenant-wide policy checks (once) ───
Write-Status "Fetching tenant-wide passkey rollout policy state..." "INFO"

$optOutSet = $false
try {
    $amp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/policies/authenticationmethodspolicy" -EA Stop
    $optOutSet = [bool]$amp.optOutSettings.passkeyDynamicMigration
} catch {
    Write-Status "Could not read optOutSettings (beta endpoint, requires Policy.Read.All): $($_.Exception.Message)" "WARN"
}
Write-Status "Tenant opt-out (passkeyDynamicMigration): $optOutSet" $(if ($optOutSet) { "WARN" } else { "OK" })

$smsState = "Unknown"
$voiceState = "Unknown"
try {
    $smsState = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms" -EA Stop).state
    $voiceState = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/authenticationMethodConfigurations/Voice" -EA Stop).state
} catch {
    Write-Status "Could not read Sms/Voice method policy state: $($_.Exception.Message)" "WARN"
}
Write-Status "SMS policy state: $smsState | Voice policy state: $voiceState" "INFO"

$campaignState = "Unknown"
try {
    $campaign = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/authenticationMethodsPolicy/registrationEnforcement" -EA Stop
    $campaignState = $campaign.authenticationMethodsRegistrationCampaign.state
} catch {
    Write-Status "Could not read Registration Campaign state: $($_.Exception.Message)" "WARN"
}
Write-Status "Registration Campaign state: $campaignState" "INFO"

# ─── Build target user list ───
$targetUsers = @()
if ($PSCmdlet.ParameterSetName -eq "All") {
    Write-Status "Fetching up to $Top enabled users..." "INFO"
    $targetUsers = Get-MgUser -Filter "accountEnabled eq true" -Top $Top -Property Id,UserPrincipalName,DisplayName -EA Stop
} else {
    foreach ($upn in $UserPrincipalName) {
        try {
            $targetUsers += Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName -EA Stop
        } catch {
            Write-Status "User not found: $upn" "ERROR"
        }
    }
}

if (-not $targetUsers -or $targetUsers.Count -eq 0) {
    Write-Status "No users to process. Specify -UserPrincipalName or -All." "ERROR"
    return
}

# ─── Process each user ───
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($user in $targetUsers) {
    $upn = $user.UserPrincipalName
    Write-Status "Processing: $upn" "INFO"

    $result = [PSCustomObject]@{
        UserPrincipalName        = $upn
        DisplayName              = $user.DisplayName
        HasSmsOrVoiceMethod      = $false
        HasPhishingResistantMethod = $false
        RegisteredMethodTypes    = "Unknown"
        SsprEligibleMethodCount  = 0
        RiskFlag                 = "Unknown"
        Errors                   = ""
    }

    try {
        $methods = Get-MgUserAuthenticationMethod -UserId $user.Id -EA Stop
        $typeList = $methods | ForEach-Object { $_.AdditionalProperties["@odata.type"] }
        $result.RegisteredMethodTypes = if ($typeList) { ($typeList -replace "#microsoft.graph.", "") -join " | " } else { "NONE" }

        $result.HasSmsOrVoiceMethod = [bool]($typeList | Where-Object { $_ -in $smsVoiceTypes })
        $result.HasPhishingResistantMethod = [bool]($typeList | Where-Object { $_ -in $phishingResistantTypes })

        # SSPR-eligible = any registered method other than password itself
        $result.SsprEligibleMethodCount = ($typeList | Where-Object { $_ -ne "#microsoft.graph.passwordAuthenticationMethod" } | Measure-Object).Count
    } catch {
        $result.Errors += "Auth methods lookup failed: $($_.Exception.Message); "
    }

    # ─── Risk classification ───
    $result.RiskFlag =
        if ($result.HasPhishingResistantMethod) {
            "NO_ACTION_NEEDED"
        } elseif ($result.HasSmsOrVoiceMethod -and $result.SsprEligibleMethodCount -gt 1) {
            "WILL_BE_NUDGED"
        } elseif ($result.HasSmsOrVoiceMethod -and $result.SsprEligibleMethodCount -le 1) {
            "AT_RISK_FEB2027"
        } elseif ($result.SsprEligibleMethodCount -eq 0) {
            "NO_MFA_METHOD_AT_ALL"
        } else {
            "REVIEW_MANUALLY"
        }

    $allResults.Add($result)

    $flag = switch ($result.RiskFlag) {
        "NO_ACTION_NEEDED"     { "OK" }
        "WILL_BE_NUDGED"       { "INFO" }
        "AT_RISK_FEB2027"      { "WARN" }
        "NO_MFA_METHOD_AT_ALL" { "ERROR" }
        default                { "WARN" }
    }
    Write-Status "  $($result.RiskFlag) — methods: $($result.RegisteredMethodTypes)" $flag
}

# ─── Export ───
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== Passkey Default Auth Rollout Readiness Summary ===" -ForegroundColor Cyan
Write-Host "Tenant opt-out set (passkeyDynamicMigration): $optOutSet"
Write-Host "SMS policy: $smsState | Voice policy: $voiceState | Registration Campaign: $campaignState`n"

$allResults | Group-Object RiskFlag | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize

$atRisk = ($allResults | Where-Object RiskFlag -eq "AT_RISK_FEB2027").Count
$noMfa  = ($allResults | Where-Object RiskFlag -eq "NO_MFA_METHOD_AT_ALL").Count
if ($atRisk -gt 0) {
    Write-Status "$atRisk user(s) have SMS/Voice as their only real MFA method — will hit the BLOCKING passkey prompt on/after Feb 1, 2027 if not migrated. See PasskeyDefaultAuth-B.md Fix 2/3." "WARN"
}
if ($noMfa -gt 0) {
    Write-Status "$noMfa user(s) have NO MFA method registered at all — this is a pre-existing gap unrelated to the passkey rollout; escalate separately." "ERROR"
}
if ($optOutSet) {
    Write-Status "Tenant has the temporary opt-out set — remember this only delays Phase 1 (nudging); it does NOT delay the Feb 1, 2027 enforcement." "WARN"
}
