<#
.SYNOPSIS
    Read-only audit of a tenant's exposure to Microsoft's MOERA (onmicrosoft.com) restrictions:
    the Teams outbound external-messaging limit (MC1463510) and the Exchange Online external-recipient cap.

.DESCRIPTION
    Checks, in order:
      1. Domains (Microsoft Graph): is any custom domain verified? Is the default domain MOERA?
         -> Tenant is in scope for the Teams limit (MC1463510) only if NO custom domain is verified.
      2. Users (Graph, optional -IncludeUsers): count of enabled users whose UPN is still on *.onmicrosoft.com.
      3. Exchange (optional -IncludeExchange): mailboxes whose PrimarySmtpAddress is *.onmicrosoft.com
         -> exposure to the Exchange external-recipient cap for MOERA senders, even in tenants that are
            out of scope for the Teams limit.
      4. Teams (optional -IncludeTeams): tenant federation configuration, so a "cannot message externals"
         report can be separated from a federation/policy block.

    Produces a findings CSV (one row per check) and, with -IncludeExchange, a mailbox CSV.

    Does NOT change any setting. Cannot read Teams throttle state - Microsoft exposes none (as of Sept 2026).

.PARAMETER IncludeUsers
    Count enabled users with a MOERA UPN (Graph User.Read.All).

.PARAMETER IncludeExchange
    Query Exchange Online for mailboxes with a MOERA primary SMTP address (requires ExchangeOnlineManagement).

.PARAMETER IncludeTeams
    Read Get-CsTenantFederationConfiguration (requires MicrosoftTeams module).

.PARAMETER SkipConnect
    Assume Connect-MgGraph / Connect-ExchangeOnline / Connect-MicrosoftTeams have already been run.

.PARAMETER OutputFolder
    Folder for CSV output. Default: current directory.

.EXAMPLE
    .\Get-MOERAOnlyTenantExposure.ps1

.EXAMPLE
    .\Get-MOERAOnlyTenantExposure.ps1 -IncludeUsers -IncludeExchange -IncludeTeams -OutputFolder C:\Temp

.NOTES
    Requires : Microsoft.Graph.Identity.DirectoryManagement (+ Microsoft.Graph.Users with -IncludeUsers)
               ExchangeOnlineManagement (with -IncludeExchange), MicrosoftTeams (with -IncludeTeams)
    Roles    : Global Reader is sufficient for all checks.
    Safety   : read-only. Windows PowerShell 5.1 and PowerShell 7 compatible.
#>
[CmdletBinding()]
param(
    [switch]$IncludeUsers,
    [switch]$IncludeExchange,
    [switch]$IncludeTeams,
    [switch]$SkipConnect,
    [string]$OutputFolder = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$stamp    = Get-Date -Format 'yyyyMMdd_HHmm'
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Check, [string]$Result, [string]$Status, [string]$Detail)
    $findings.Add([pscustomobject]@{ Check = $Check; Result = $Result; Status = $Status; Detail = $Detail })
    Write-Status ("{0}: {1} {2}" -f $Check, $Result, $Detail) $Status
}

# ---------------- Preflight ----------------
if (-not (Test-Path -Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Identity.DirectoryManagement')) {
    Write-Status "Microsoft.Graph.Identity.DirectoryManagement not installed - Install-Module Microsoft.Graph" "ERROR"
    throw "Missing Graph module"
}
if (-not $SkipConnect) {
    $scopes = @('Domain.Read.All')
    if ($IncludeUsers) { $scopes += 'User.Read.All' }
    Connect-MgGraph -Scopes $scopes -NoWelcome
}

# ---------------- Detect: domains ----------------
$domains  = @(Get-MgDomain -All)
$verified = @($domains | Where-Object { $_.IsVerified })
$custom   = @($verified | Where-Object { -not $_.IsInitial -and $_.Id -notlike '*.onmicrosoft.com' })
$default  = @($domains | Where-Object { $_.IsDefault })

$moeraOnly = ($custom.Count -eq 0)
if ($moeraOnly) {
    Add-Finding -Check 'TeamsMOERAScope' -Result 'IN SCOPE' -Status 'ERROR' `
        -Detail 'No verified custom domain - Teams outbound external messaging can be throttled (MC1463510). Fix: add + verify a custom domain.'
} else {
    Add-Finding -Check 'TeamsMOERAScope' -Result 'Out of scope' -Status 'OK' `
        -Detail ("Verified custom domain(s): {0}" -f (($custom | ForEach-Object { $_.Id }) -join ', '))
}

if ($default.Count -gt 0 -and $default[0].Id -like '*.onmicrosoft.com') {
    Add-Finding -Check 'DefaultDomain' -Result $default[0].Id -Status 'WARN' `
        -Detail 'Default domain is MOERA - new users/groups get onmicrosoft.com addresses (Exchange cap exposure).'
} elseif ($default.Count -gt 0) {
    Add-Finding -Check 'DefaultDomain' -Result $default[0].Id -Status 'OK' -Detail ''
}

$unverified = @($domains | Where-Object { -not $_.IsVerified })
if ($unverified.Count -gt 0) {
    Add-Finding -Check 'UnverifiedDomains' -Result ([string]$unverified.Count) -Status 'WARN' `
        -Detail ("Added but not verified (do not count toward scope exit): {0}" -f (($unverified | ForEach-Object { $_.Id }) -join ', '))
}

# ---------------- Detect: users ----------------
if ($IncludeUsers) {
    try {
        $users = @(Get-MgUser -All -Filter 'accountEnabled eq true' -Property 'userPrincipalName,userType' |
                   Where-Object { $_.UserType -eq 'Member' -and $_.UserPrincipalName -like '*.onmicrosoft.com' })
        $status = 'OK'
        if ($users.Count -gt 0) { $status = 'WARN' }
        Add-Finding -Check 'MemberUsersOnMOERAUpn' -Result ([string]$users.Count) -Status $status `
            -Detail 'Enabled member users whose UPN is *.onmicrosoft.com (includes break-glass/service accounts by design).'
        if ($users.Count -gt 0) {
            $users | Select-Object UserPrincipalName |
                Export-Csv -Path (Join-Path $OutputFolder "MOERA_Users_$stamp.csv") -NoTypeInformation -Encoding UTF8
        }
    } catch {
        Add-Finding -Check 'MemberUsersOnMOERAUpn' -Result 'ERROR' -Status 'ERROR' -Detail $_.Exception.Message
    }
}

# ---------------- Detect: Exchange ----------------
if ($IncludeExchange) {
    try {
        if (-not (Get-Command -Name Get-EXOMailbox -ErrorAction SilentlyContinue)) {
            Import-Module ExchangeOnlineManagement
        }
        if (-not $SkipConnect) { Connect-ExchangeOnline -ShowBanner:$false }
        $mbx = @(Get-EXOMailbox -ResultSize Unlimited -Properties PrimarySmtpAddress, RecipientTypeDetails |
                 Where-Object { [string]$_.PrimarySmtpAddress -like '*.onmicrosoft.com' })
        $userMbx = @($mbx | Where-Object { $_.RecipientTypeDetails -eq 'UserMailbox' })
        $status = 'OK'
        if ($userMbx.Count -gt 0) { $status = 'WARN' }
        Add-Finding -Check 'MailboxesWithMOERAPrimarySmtp' -Result ("{0} (user: {1})" -f $mbx.Count, $userMbx.Count) -Status $status `
            -Detail 'These senders are subject to the Exchange external-recipient cap for onmicrosoft.com addresses.'
        if ($mbx.Count -gt 0) {
            $mbx | Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails |
                Export-Csv -Path (Join-Path $OutputFolder "MOERA_Mailboxes_$stamp.csv") -NoTypeInformation -Encoding UTF8
        }
    } catch {
        Add-Finding -Check 'MailboxesWithMOERAPrimarySmtp' -Result 'ERROR' -Status 'ERROR' -Detail $_.Exception.Message
    }
}

# ---------------- Detect: Teams federation ----------------
if ($IncludeTeams) {
    try {
        if (-not (Get-Command -Name Get-CsTenantFederationConfiguration -ErrorAction SilentlyContinue)) {
            Import-Module MicrosoftTeams
        }
        if (-not $SkipConnect) { Connect-MicrosoftTeams | Out-Null }
        $fed = Get-CsTenantFederationConfiguration
        $status = 'OK'
        if (-not $fed.AllowFederatedUsers) { $status = 'WARN' }
        Add-Finding -Check 'TeamsFederation' -Result ("AllowFederatedUsers={0}; AllowTeamsConsumer={1}" -f $fed.AllowFederatedUsers, $fed.AllowTeamsConsumer) `
            -Status $status -Detail 'If AllowFederatedUsers is False, external chat is blocked by policy - not by MC1463510.'
    } catch {
        Add-Finding -Check 'TeamsFederation' -Result 'ERROR' -Status 'ERROR' -Detail $_.Exception.Message
    }
}

# ---------------- Report ----------------
$outFile = Join-Path $OutputFolder "MOERA_Exposure_$stamp.csv"
$findings | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8
Write-Host ""
if ($moeraOnly) {
    Write-Status "RESULT: MOERA-only tenant - in scope for Teams external messaging limits AND the Exchange recipient cap." "ERROR"
} else {
    Write-Status "RESULT: tenant has a verified custom domain - out of scope for MC1463510." "OK"
}
Write-Status ("Findings written: {0}" -f $outFile) "OK"
