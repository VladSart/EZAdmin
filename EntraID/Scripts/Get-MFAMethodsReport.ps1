<#
.SYNOPSIS
    Reports registered MFA authentication methods, per-user MFA state, and Conditional
    Access MFA coverage for a set of Entra ID users (or the whole tenant).

.DESCRIPTION
    Connects to Microsoft Graph and, for each target user, reports:
    - Registered authentication methods (Authenticator, phone, FIDO2, TAP, etc.)
    - Legacy per-user MFA state (enabled/enforced/disabled) — flags conflicts with CA
    - Whether the user is covered by at least one enabled CA policy that grants MFA
    - Whether the user is explicitly excluded (directly or via group) from all such policies
    - Sign-in MFA error count in the lookback window (error codes 50074/50076/50158/53004/500121)

    This directly answers the two questions escalation tickets always need first:
    "does this user have MFA registered" and "is MFA actually being enforced for them."

    Exports results to CSV and prints a colour-coded console summary. Read-only — makes
    no changes to auth methods, CA policies, or per-user MFA state.

    Does NOT cover:
    - Issuing a Temporary Access Pass or removing a broken auth method (see Fix 1/Fix 2
      in EntraID/Troubleshooting/MFA-B.md — those are intentionally left as manual/ticketed
      actions, not automated by this reporting script)
    - Security Defaults detail beyond enabled/disabled

.PARAMETER UserPrincipalName
    One or more UPNs to report on. If omitted, use -All to report on every enabled user
    (can be slow / throttled on large tenants — use with -Top to cap it).

.PARAMETER All
    Report on all enabled users in the tenant instead of a specific list.

.PARAMETER Top
    Maximum number of users to process when -All is used. Default: 200.

.PARAMETER DaysBack
    Lookback window in days for sign-in MFA error counting. Default: 7.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\MFA-Report-<timestamp>.csv

.EXAMPLE
    .\Get-MFAMethodsReport.ps1 -UserPrincipalName alice@contoso.com,bob@contoso.com

.EXAMPLE
    .\Get-MFAMethodsReport.ps1 -All -Top 500 -DaysBack 14

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: UserAuthenticationMethod.Read.All, Policy.Read.All,
                   AuditLog.Read.All, User.Read.All, Group.Read.All, GroupMember.Read.All
    Run As: An account with Reports Reader, Global Reader, or Authentication Policy
            Administrator (read) role — does not require write permissions
    Safe: Read-only — no MFA methods, CA policies, or per-user MFA states are changed
    Cross-references: EntraID/Troubleshooting/MFA-B.md (Diagnosis Steps 1-5, Fix 1-4)
#>

[CmdletBinding(DefaultParameterSetName = "ByUser")]
param(
    [Parameter(ParameterSetName = "ByUser")]
    [string[]]$UserPrincipalName,

    [Parameter(ParameterSetName = "All")]
    [switch]$All,

    [Parameter(ParameterSetName = "All")]
    [int]$Top = 200,

    [int]$DaysBack = 7,

    [string]$OutputPath = ".\MFA-Report-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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
        Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","Policy.Read.All","AuditLog.Read.All","User.Read.All","Group.Read.All","GroupMember.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── Pre-fetch tenant-wide policy state (once, not per-user) ───
Write-Status "Fetching Security Defaults and Conditional Access policies..." "INFO"

$securityDefaultsEnabled = $false
try {
    $secDefaults = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
    $securityDefaultsEnabled = [bool]$secDefaults.isEnabled
} catch {
    Write-Status "Could not read Security Defaults policy: $($_.Exception.Message)" "WARN"
}

$mfaCaPolicies = @()
try {
    $mfaCaPolicies = Get-MgIdentityConditionalAccessPolicy -All -EA Stop |
        Where-Object { $_.State -eq "enabled" -and $_.GrantControls.BuiltInControls -contains "mfa" }
    Write-Status "Found $($mfaCaPolicies.Count) enabled CA polic(ies) that grant MFA" "INFO"
} catch {
    Write-Status "Could not read Conditional Access policies (requires Policy.Read.All): $($_.Exception.Message)" "WARN"
}

# Cache group membership lookups to avoid repeat Graph calls
$script:GroupMemberCache = @{}
function Test-UserInGroup {
    param([string]$GroupId, [string]$UserId)
    if (-not $script:GroupMemberCache.ContainsKey($GroupId)) {
        try {
            $script:GroupMemberCache[$GroupId] = (Get-MgGroupMember -GroupId $GroupId -All -EA Stop).Id
        } catch {
            $script:GroupMemberCache[$GroupId] = @()
        }
    }
    return $script:GroupMemberCache[$GroupId] -contains $UserId
}

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
$cutoffDate = (Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-ddTHH:mm:ssZ')
$mfaErrorCodes = @(50074, 50076, 50158, 53004, 500121)

foreach ($user in $targetUsers) {
    $upn = $user.UserPrincipalName
    Write-Status "Processing: $upn" "INFO"

    $result = [PSCustomObject]@{
        UserPrincipalName   = $upn
        DisplayName         = $user.DisplayName
        RegisteredMethods   = "Unknown"
        MethodCount         = 0
        PerUserMfaState     = "Unknown"
        CoveredByCAPolicy   = "Unknown"
        CAPolicyNames       = "None"
        ExcludedFromAllCA   = $false
        ExclusionDetail     = "None"
        SecurityDefaultsOn  = $securityDefaultsEnabled
        MfaErrorCount       = 0
        LastMfaError        = "None"
        Errors              = ""
    }

    try {
        $methods = Get-MgUserAuthenticationMethod -UserId $user.Id -EA Stop |
            Where-Object { $_.AdditionalProperties["@odata.type"] -ne "#microsoft.graph.passwordAuthenticationMethod" }
        $result.MethodCount = ($methods | Measure-Object).Count
        $result.RegisteredMethods = if ($methods) {
            ($methods | ForEach-Object { ($_.AdditionalProperties["@odata.type"] -replace "#microsoft.graph.", "" -replace "AuthenticationMethod", "") }) -join " | "
        } else { "NONE — user cannot complete MFA" }
    } catch {
        $result.Errors += "Auth methods lookup failed: $($_.Exception.Message); "
    }

    try {
        $uri = "https://graph.microsoft.com/beta/users/$($user.Id)/authentication/requirements"
        $perUser = Invoke-MgGraphRequest -Method GET -Uri $uri -EA Stop
        $result.PerUserMfaState = $perUser.perUserMfaState
    } catch {
        $result.Errors += "Per-user MFA state lookup failed: $($_.Exception.Message); "
    }

    if ($mfaCaPolicies.Count -gt 0) {
        $coveringPolicies = @()
        $excludedFromAll = $true
        foreach ($policy in $mfaCaPolicies) {
            $includeAll  = $policy.Conditions.Users.IncludeUsers -contains "All"
            $includeUser = $policy.Conditions.Users.IncludeUsers -contains $user.Id
            $isIncluded  = $includeAll -or $includeUser

            if (-not $isIncluded) { continue }

            $excludedDirect = $policy.Conditions.Users.ExcludeUsers -contains $user.Id
            $excludedGroup  = $false
            foreach ($gid in $policy.Conditions.Users.ExcludeGroups) {
                if (Test-UserInGroup -GroupId $gid -UserId $user.Id) { $excludedGroup = $true; break }
            }

            if ($excludedDirect -or $excludedGroup) {
                continue
            }

            $coveringPolicies += $policy.DisplayName
            $excludedFromAll = $false
        }

        $result.CoveredByCAPolicy = $coveringPolicies.Count -gt 0
        $result.CAPolicyNames     = if ($coveringPolicies.Count -gt 0) { $coveringPolicies -join " | " } else { "None" }
        $result.ExcludedFromAllCA = $excludedFromAll -and $mfaCaPolicies.Count -gt 0
    } else {
        $result.CoveredByCAPolicy = "N/A (no CA policies readable or none require MFA)"
    }

    try {
        $signIns = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn' and createdDateTime gt $cutoffDate" -Top 50 -EA Stop |
            Where-Object { $_.Status.ErrorCode -in $mfaErrorCodes }
        $result.MfaErrorCount = ($signIns | Measure-Object).Count
        if ($signIns) {
            $latest = $signIns | Sort-Object CreatedDateTime -Descending | Select-Object -First 1
            $result.LastMfaError = "$($latest.CreatedDateTime) — Error $($latest.Status.ErrorCode): $($latest.Status.FailureReason)"
        }
    } catch {
        $result.Errors += "Sign-in log lookup failed: $($_.Exception.Message); "
    }

    $allResults.Add($result)

    $flag = if ($result.MethodCount -eq 0) { "ERROR" }
            elseif ($result.ExcludedFromAllCA -and -not $securityDefaultsEnabled -and $result.PerUserMfaState -ne "enforced") { "WARN" }
            else { "OK" }
    Write-Status "  Methods: $($result.MethodCount) | Per-user state: $($result.PerUserMfaState) | CA covered: $($result.CoveredByCAPolicy)" $flag
}

# ─── Export ───
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== MFA Coverage Summary ===" -ForegroundColor Cyan
$allResults | Format-Table UserPrincipalName, MethodCount, PerUserMfaState, CoveredByCAPolicy, ExcludedFromAllCA, MfaErrorCount -AutoSize

$noMethod = ($allResults | Where-Object MethodCount -eq 0).Count
$noCoverage = ($allResults | Where-Object { $_.ExcludedFromAllCA -eq $true -and $_.PerUserMfaState -ne "enforced" -and -not $securityDefaultsEnabled }).Count
if ($noMethod -gt 0) { Write-Status "$noMethod user(s) have NO MFA method registered" "ERROR" }
if ($noCoverage -gt 0) { Write-Status "$noCoverage user(s) appear to have NO MFA enforcement path at all — investigate" "WARN" }
