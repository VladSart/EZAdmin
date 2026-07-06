<#
.SYNOPSIS
    Reports Self-Service Password Reset (SSPR) registration coverage across tenant users,
    flagging accounts that cannot successfully complete an SSPR reset today.

.DESCRIPTION
    Connects to Microsoft Graph and, for each target user, reports:
    - Number and type of registered authentication methods usable for SSPR
    - Whether the user meets the "2 methods" bar commonly required by SSPR policy
      (method count only — actual required-count is a tenant policy setting configured
      in the portal and is not fully exposed via Graph; see NOTES)
    - Admin-role membership, since admin accounts cannot use security questions and are
      held to a stricter policy (2 non-security-question methods minimum)
    - Whether the account is licensed for SSPR (Entra ID P1/P2 or equivalent)

    This directly answers the question every "user is locked out and can't reset their
    own password" ticket needs first: has this person actually registered enough SSPR
    methods, and are they an admin subject to the stricter policy.

    Exports results to CSV and prints a colour-coded console summary. Read-only — makes
    no changes to auth methods, licenses, or SSPR policy.

    Does NOT cover:
    - Password Writeback health for hybrid tenants (service state, connector permissions,
      Fine-Grained Password Policy) — see EntraID/Troubleshooting/SSPR-A.md Validation
      Steps 3-4 and Troubleshooting Phase 3 for that
    - SSPR audit log analysis for a specific failed reset attempt — see SSPR-A.md
      Evidence Pack (Collect-SSPREvidence.ps1) for single-user deep dive

.PARAMETER UserPrincipalName
    One or more UPNs to report on. If omitted, use -All to report on every enabled user
    (can be slow / throttled on large tenants — use with -Top to cap it).

.PARAMETER All
    Report on all enabled users in the tenant instead of a specific list.

.PARAMETER Top
    Maximum number of users to process when -All is used. Default: 300.

.PARAMETER RequiredMethodCount
    Number of registered methods considered "compliant" with your tenant's SSPR policy.
    Default: 2 (the common configuration). Set to 1 if your tenant only requires one.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\SSPR-Coverage-Report-<timestamp>.csv

.EXAMPLE
    .\Get-SSPRCoverageReport.ps1 -UserPrincipalName alice@contoso.com,bob@contoso.com

.EXAMPLE
    .\Get-SSPRCoverageReport.ps1 -All -Top 500 -RequiredMethodCount 2

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: UserAuthenticationMethod.Read.All, User.Read.All,
                   RoleManagement.Read.Directory, Directory.Read.All
    Run As: An account with Reports Reader, Global Reader, or Authentication Policy
            Administrator (read) role — does not require write permissions
    Safe: Read-only — no auth methods, licenses, or policies are changed
    Cross-references: EntraID/Troubleshooting/SSPR-A.md (Validation Steps, Playbook 4)

    Known limitation: the tenant-wide "number of methods required to reset" and
    "SSPR enabled for All/Selected/None" settings are portal-only (Entra ID > Password
    reset > Properties) and are not fully readable via stable Graph endpoints at time
    of writing. This script reports registered method counts against -RequiredMethodCount
    as a stand-in; confirm the actual policy setting in the portal before treating
    "NON_COMPLIANT" results as certain gaps.
#>

[CmdletBinding(DefaultParameterSetName = "ByUser")]
param(
    [Parameter(ParameterSetName = "ByUser")]
    [string[]]$UserPrincipalName,

    [Parameter(ParameterSetName = "All")]
    [switch]$All,

    [Parameter(ParameterSetName = "All")]
    [int]$Top = 300,

    [int]$RequiredMethodCount = 2,

    [string]$OutputPath = ".\SSPR-Coverage-Report-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# Method types Microsoft counts toward SSPR (password itself never counts)
$sspRelevantTypes = @(
    "microsoft.graph.microsoftAuthenticatorAuthenticationMethod",
    "microsoft.graph.phoneAuthenticationMethod",
    "microsoft.graph.emailAuthenticationMethod",
    "microsoft.graph.softwareOathAuthenticationMethod",
    "microsoft.graph.fido2AuthenticationMethod",
    "microsoft.graph.securityQuestionAuthenticationMethod"
)

# ─── Connect ───
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All","RoleManagement.Read.Directory","Directory.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── Pre-fetch admin role members (once, not per-user) ───
Write-Status "Fetching directory role assignments to identify admin accounts..." "INFO"

$adminUserIds = @{}
try {
    $roles = Get-MgDirectoryRole -All -EA Stop
    foreach ($role in $roles) {
        try {
            $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -EA Stop
            foreach ($m in $members) { $adminUserIds[$m.Id] = $true }
        } catch { }
    }
    Write-Status "Found $($adminUserIds.Count) unique user(s) holding at least one directory role" "INFO"
} catch {
    Write-Status "Could not read directory roles (requires RoleManagement.Read.Directory): $($_.Exception.Message)" "WARN"
}

# ─── Build target user list ───
$targetUsers = @()
if ($PSCmdlet.ParameterSetName -eq "All") {
    Write-Status "Fetching up to $Top enabled users..." "INFO"
    $targetUsers = Get-MgUser -Filter "accountEnabled eq true" -Top $Top -Property Id,UserPrincipalName,DisplayName,AssignedLicenses -EA Stop
} else {
    foreach ($upn in $UserPrincipalName) {
        try {
            $targetUsers += Get-MgUser -UserId $upn -Property Id,UserPrincipalName,DisplayName,AssignedLicenses -EA Stop
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

    $isAdmin = $adminUserIds.ContainsKey($user.Id)

    $result = [PSCustomObject]@{
        UserPrincipalName     = $upn
        DisplayName           = $user.DisplayName
        IsAdmin               = $isAdmin
        Licensed              = ($user.AssignedLicenses.Count -gt 0)
        SSPRMethodCount        = 0
        NonQuestionMethodCount = 0
        RegisteredMethods      = "None"
        ComplianceStatus       = "Unknown"
        Errors                 = ""
    }

    try {
        $methods = Get-MgUserAuthenticationMethod -UserId $user.Id -EA Stop |
            Where-Object { $_.AdditionalProperties["@odata.type"] -in $sspRelevantTypes }

        $result.SSPRMethodCount = ($methods | Measure-Object).Count
        $result.NonQuestionMethodCount = ($methods | Where-Object {
            $_.AdditionalProperties["@odata.type"] -ne "microsoft.graph.securityQuestionAuthenticationMethod"
        } | Measure-Object).Count

        $result.RegisteredMethods = if ($methods) {
            ($methods | ForEach-Object {
                ($_.AdditionalProperties["@odata.type"] -replace "microsoft.graph.", "" -replace "AuthenticationMethod", "")
            }) -join " | "
        } else { "NONE — user cannot complete SSPR" }
    } catch {
        $result.Errors += "Auth methods lookup failed: $($_.Exception.Message); "
    }

    # Admins cannot use security questions — evaluate against NonQuestionMethodCount instead
    $effectiveCount = if ($isAdmin) { $result.NonQuestionMethodCount } else { $result.SSPRMethodCount }

    $result.ComplianceStatus = if (-not $result.Licensed) {
        "UNLICENSED"
    } elseif ($effectiveCount -eq 0) {
        "NOT_REGISTERED"
    } elseif ($effectiveCount -lt $RequiredMethodCount) {
        "BELOW_THRESHOLD"
    } else {
        "COMPLIANT"
    }

    $allResults.Add($result)

    $flag = switch ($result.ComplianceStatus) {
        "NOT_REGISTERED"  { "ERROR" }
        "BELOW_THRESHOLD" { "WARN" }
        "UNLICENSED"      { "WARN" }
        default           { "OK" }
    }
    Write-Status "  Methods: $($result.SSPRMethodCount) (non-question: $($result.NonQuestionMethodCount)) | Admin: $isAdmin | Status: $($result.ComplianceStatus)" $flag
}

# ─── Export ───
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== SSPR Coverage Summary ===" -ForegroundColor Cyan
$allResults | Format-Table UserPrincipalName, IsAdmin, SSPRMethodCount, NonQuestionMethodCount, ComplianceStatus -AutoSize

$notRegistered  = ($allResults | Where-Object ComplianceStatus -eq "NOT_REGISTERED").Count
$belowThreshold = ($allResults | Where-Object ComplianceStatus -eq "BELOW_THRESHOLD").Count
$unlicensed     = ($allResults | Where-Object ComplianceStatus -eq "UNLICENSED").Count
if ($notRegistered -gt 0)  { Write-Status "$notRegistered user(s) have NO SSPR method registered — cannot self-reset today" "ERROR" }
if ($belowThreshold -gt 0) { Write-Status "$belowThreshold user(s) are below the $RequiredMethodCount-method threshold" "WARN" }
if ($unlicensed -gt 0)     { Write-Status "$unlicensed user(s) have no license assigned — SSPR may not be available" "WARN" }
if (($notRegistered + $belowThreshold + $unlicensed) -eq 0) { Write-Status "All processed users are SSPR-compliant" "OK" }
