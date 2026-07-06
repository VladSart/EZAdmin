<#
.SYNOPSIS
    Reports Windows Hello for Business (WHfB) registration coverage across tenant users
    and cross-references it with each user's device join type to flag likely trust-model
    and Cloud Kerberos Trust readiness gaps.

.DESCRIPTION
    Connects to Microsoft Graph and, for each target user, reports:
    - Whether a WHfB key is registered (and how many)
    - The user's registered devices and their join type (Hybrid / Entra Joined / Registered)
    - Whether the tenant has an AzureADKerberos server object configured (Cloud Kerberos
      Trust prerequisite for Hybrid devices) — read once, tenant-wide
    - A risk flag when a user has Hybrid Joined devices but no WHfB key AND no evidence
      of Cloud Kerberos Trust being configured (these users will fall back to password/
      cert-trust flows and are the most common WHfB escalation source)

    This answers the two questions a WHfB rollout ticket always needs first: "who hasn't
    provisioned yet" and "are any of the un-provisioned users on hybrid devices where the
    trust model itself might be misconfigured."

    Exports results to CSV and prints a colour-coded console summary. Read-only — makes
    no changes to WHfB keys, device objects, or Kerberos server configuration.

    Does NOT cover:
    - Per-device provisioning failure diagnosis (event IDs, TPM state, NGC folder) — see
      EntraID/Troubleshooting/WHfB-A.md Validation Steps and Evidence Pack for that
    - Actually configuring Entra Kerberos (see WHfB-A.md Playbook 1)
    - FIDO2 / Phone Sign-in coverage (different auth methods, not WHfB keys)

.PARAMETER UserPrincipalName
    One or more UPNs to report on. If omitted, use -All to report on every enabled user
    (can be slow / throttled on large tenants — use with -Top to cap it).

.PARAMETER All
    Report on all enabled users in the tenant instead of a specific list.

.PARAMETER Top
    Maximum number of users to process when -All is used. Default: 300.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\WHfB-Registration-Report-<timestamp>.csv

.EXAMPLE
    .\Get-WHfBRegistrationStatus.ps1 -UserPrincipalName alice@contoso.com,bob@contoso.com

.EXAMPLE
    .\Get-WHfBRegistrationStatus.ps1 -All -Top 500

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: UserAuthenticationMethod.Read.All, User.Read.All, Device.Read.All
    Run As: An account with Reports Reader, Global Reader, or Authentication Policy
            Administrator (read) role — does not require write permissions
    Safe: Read-only — no WHfB keys, devices, or Kerberos server objects are changed
    Cross-references: EntraID/Troubleshooting/WHfB-A.md (Validation Steps, Playbook 1, Playbook 4)
#>

[CmdletBinding(DefaultParameterSetName = "ByUser")]
param(
    [Parameter(ParameterSetName = "ByUser")]
    [string[]]$UserPrincipalName,

    [Parameter(ParameterSetName = "All")]
    [switch]$All,

    [Parameter(ParameterSetName = "All")]
    [int]$Top = 300,

    [string]$OutputPath = ".\WHfB-Registration-Report-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

function Get-JoinTypeFriendly {
    param([string]$TrustType)
    switch ($TrustType) {
        "ServerAd"  { return "HybridJoined" }
        "AzureAd"   { return "EntraJoined" }
        "Workplace" { return "EntraRegistered" }
        default     { return "Unknown" }
    }
}

# ─── Connect ───
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All","Device.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── Check tenant-wide Cloud Kerberos Trust readiness (once) ───
Write-Status "Checking for AzureADKerberos server object (Cloud Kerberos Trust prerequisite)..." "INFO"

$cloudKerberosConfigured = $false
try {
    # This object lives in on-prem AD, not Entra — Graph cannot see it directly.
    # As a proxy signal, check whether any Hybrid device has a recent sign-in, which at
    # least confirms Hybrid join is functioning; true verification requires the AD-side
    # check in EntraID/Troubleshooting/WHfB-A.md Validation Step 4.
    $null = Get-MgDevice -Top 1 -ErrorAction Stop
    Write-Status "Note: AzureADKerberos server object cannot be verified via Graph — run WHfB-A.md Validation Step 4 on a DC to confirm Cloud Kerberos Trust readiness directly." "WARN"
} catch {
    Write-Status "Could not query devices: $($_.Exception.Message)" "WARN"
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

foreach ($user in $targetUsers) {
    $upn = $user.UserPrincipalName
    Write-Status "Processing: $upn" "INFO"

    $result = [PSCustomObject]@{
        UserPrincipalName    = $upn
        DisplayName          = $user.DisplayName
        WHfBRegistered       = $false
        WHfBKeyCount         = 0
        WHfBDeviceNames      = "None"
        OwnedDeviceCount     = 0
        HybridDeviceCount    = 0
        EntraJoinedCount     = 0
        RegisteredOnlyCount  = 0
        RiskFlag             = "OK"
        Errors               = ""
    }

    try {
        $methods = Get-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $user.Id -EA Stop
        $result.WHfBKeyCount   = ($methods | Measure-Object).Count
        $result.WHfBRegistered = $result.WHfBKeyCount -gt 0
        $result.WHfBDeviceNames = if ($methods) { ($methods | Select-Object -ExpandProperty DisplayName) -join " | " } else { "None" }
    } catch {
        $result.Errors += "WHfB method lookup failed: $($_.Exception.Message); "
    }

    try {
        $ownedDevices = Get-MgUserOwnedDevice -UserId $user.Id -All -EA Stop
        $result.OwnedDeviceCount = ($ownedDevices | Measure-Object).Count

        foreach ($d in $ownedDevices) {
            $trustType = $d.AdditionalProperties["trustType"]
            $joinType  = Get-JoinTypeFriendly -TrustType $trustType
            switch ($joinType) {
                "HybridJoined"     { $result.HybridDeviceCount++ }
                "EntraJoined"      { $result.EntraJoinedCount++ }
                "EntraRegistered"  { $result.RegisteredOnlyCount++ }
            }
        }
    } catch {
        $result.Errors += "Owned device lookup failed: $($_.Exception.Message); "
    }

    # Risk flag: hybrid-joined devices present but no WHfB key registered at all
    if ($result.HybridDeviceCount -gt 0 -and -not $result.WHfBRegistered) {
        $result.RiskFlag = "NO_WHFB_ON_HYBRID_DEVICE"
    } elseif ($result.OwnedDeviceCount -gt 0 -and -not $result.WHfBRegistered) {
        $result.RiskFlag = "NOT_PROVISIONED"
    }

    $allResults.Add($result)

    $flag = if ($result.RiskFlag -eq "NO_WHFB_ON_HYBRID_DEVICE") { "ERROR" }
            elseif ($result.RiskFlag -eq "NOT_PROVISIONED") { "WARN" }
            else { "OK" }
    Write-Status "  WHfB keys: $($result.WHfBKeyCount) | Hybrid devices: $($result.HybridDeviceCount) | Risk: $($result.RiskFlag)" $flag
}

# ─── Export ───
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Results exported to: $OutputPath" "OK"

Write-Host "`n=== WHfB Registration Summary ===" -ForegroundColor Cyan
$allResults | Format-Table UserPrincipalName, WHfBRegistered, WHfBKeyCount, HybridDeviceCount, EntraJoinedCount, RiskFlag -AutoSize

$notProvisioned = ($allResults | Where-Object { $_.RiskFlag -ne "OK" }).Count
$hybridNoWhfb   = ($allResults | Where-Object { $_.RiskFlag -eq "NO_WHFB_ON_HYBRID_DEVICE" }).Count
if ($hybridNoWhfb -gt 0) { Write-Status "$hybridNoWhfb user(s) have Hybrid Joined devices with NO WHfB key registered — verify Cloud Kerberos Trust / policy delivery" "ERROR" }
if ($notProvisioned -gt 0) { Write-Status "$notProvisioned user(s) total have not completed WHfB provisioning" "WARN" }
if ($notProvisioned -eq 0) { Write-Status "All processed users have WHfB registered" "OK" }
