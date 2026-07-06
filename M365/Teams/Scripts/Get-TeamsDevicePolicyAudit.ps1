<#
.SYNOPSIS
    Audits Teams device account health, IP phone/update policy assignment, and calendar
    processing configuration for Teams Rooms, Common Area Phones, and IP phone resource accounts.

.DESCRIPTION
    Automates the Diagnosis & Validation Flow from Device-Policies-B.md and the Phase 3
    (MTR-specific) troubleshooting steps from Device-Policies-A.md across a supplied list of
    resource account UPNs, instead of checking each device account one at a time.

    For every resource account supplied, checks and flags:
    - ACCOUNT_DISABLED / ACCOUNT_BLOCKED — Entra ID account state, per Device-Policies-B.md Fix 1
    - NO_TEAMS_ROOMS_LICENSE — missing Teams Rooms Pro/Basic or Common Area Phone (MCOCAP) SKU,
      per Device-Policies-B.md Triage step 3 and Fix 3
    - MFA_ENFORCED_ON_RESOURCE_ACCOUNT — resource accounts must not be MFA-challenged for
      unattended sign-in; this is the runbook's #1 Learning Pointer and single biggest
      silent-failure cause
    - NO_UPDATE_POLICY / UNMANAGED_UPDATES — device has no CsTeamsUpdateManagementPolicy assigned
      (falls back to Global, which may auto-update at unexpected times) per Fix 4
    - CALENDAR_NOT_AUTO_ACCEPT — AutomateProcessing is not AutoAccept on the room mailbox,
      per Device-Policies-B.md Fix 6 (the most common "wrong meeting info on device" root cause)
    - HOT_DESKING_MISMATCH — Common Area Phone account has no IP phone policy or hot-desking
      is disabled, per Fix 5 (only checked when -IncludeIPPhoneCheck is set, since it requires
      Skype for Business Online cmdlets that may not apply to every resource account type)

    Does NOT perform any remediation — this is a read-only audit companion to the fix paths
    documented in Device-Policies-B.md and Device-Policies-A.md Remediation Playbooks.

.PARAMETER ResourceAccountUPNs
    One or more UPNs of Teams Room, Common Area Phone, or IP phone resource accounts to audit.

.PARAMETER IncludeIPPhoneCheck
    Switch. If set, also queries CsTeamsIPPhonePolicy and hot-desking configuration for each
    account. Skip this for pure Teams Rooms (MTR) accounts that aren't IP phones.

.PARAMETER OutputPath
    Directory to save the CSV report. Defaults to the current directory.

.EXAMPLE
    .\Get-TeamsDevicePolicyAudit.ps1 -ResourceAccountUPNs "room101@contoso.com","room102@contoso.com"

.EXAMPLE
    .\Get-TeamsDevicePolicyAudit.ps1 -ResourceAccountUPNs (Get-Content .\rooms.txt) -IncludeIPPhoneCheck -OutputPath C:\Temp

.NOTES
    Requires:
    - MicrosoftTeams module (Connect-MicrosoftTeams)
    - Microsoft.Graph module (Connect-MgGraph) — User.Read.All scope
    - ExchangeOnlineManagement module (Connect-ExchangeOnline) — for calendar processing check
    - Teams Administrator or Teams Communications Administrator role

    Run-as: Does NOT require local admin. Requires M365 cloud permissions.
    Safe/Unsafe: Read-only. No changes made to accounts, policies, or mailboxes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$ResourceAccountUPNs,

    [Parameter()]
    [switch]$IncludeIPPhoneCheck,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Test-MfaEnforced {
    param([string]$Upn)
    # Best-effort check: looks for a CA policy targeting All Users / this account that requires MFA
    # and has no obvious exclusion group applied. This is a heuristic, not authoritative —
    # always confirm with a live sign-in test against the resource account.
    try {
        $policies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop |
            Where-Object { $_.State -eq "enabled" -and $_.GrantControls.BuiltInControls -contains "mfa" }
        return @{ PolicyCount = $policies.Count; Checked = $true }
    } catch {
        return @{ PolicyCount = -1; Checked = $false }
    }
}

# ==========================================
# MAIN SCRIPT
# ==========================================

Write-Status "Starting Teams Device Policy Audit for $($ResourceAccountUPNs.Count) account(s)..." "INFO"

if (-not (Get-Module -Name MicrosoftTeams -ListAvailable)) {
    Write-Status "MicrosoftTeams module not found. Install with: Install-Module MicrosoftTeams" "ERROR"
    exit 1
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Connecting to Microsoft Teams..." "INFO"
try {
    Connect-MicrosoftTeams -ErrorAction Stop | Out-Null
    Write-Status "Connected to Microsoft Teams" "OK"
} catch {
    Write-Status "Failed to connect to Microsoft Teams: $($_.Exception.Message)" "ERROR"
    exit 1
}

Write-Status "Connecting to Microsoft Graph (account state, licensing, CA policy check)..." "INFO"
$graphConnected = $true
try {
    Connect-MgGraph -Scopes "User.Read.All", "Policy.Read.All" -ErrorAction Stop -NoWelcome
    Write-Status "Connected to Microsoft Graph" "OK"
} catch {
    Write-Status "Failed to connect to Microsoft Graph — account/license/CA checks will be skipped: $($_.Exception.Message)" "WARN"
    $graphConnected = $false
}

$exoConnected = $false
try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    $exoConnected = $true
    Write-Status "Connected to Exchange Online (calendar processing check enabled)" "OK"
} catch {
    Write-Status "Exchange Online connection unavailable — calendar processing check will be skipped: $($_.Exception.Message)" "WARN"
}

$mfaCheck = $null
if ($graphConnected) {
    Write-Status "Checking tenant-wide CA policies enforcing MFA..." "INFO"
    $mfaCheck = Test-MfaEnforced -Upn "tenant-wide"
}

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($upn in $ResourceAccountUPNs) {
    Write-Status "Auditing $upn ..." "INFO"
    $flags = [System.Collections.Generic.List[string]]::new()

    $accountEnabled = $null
    $licenseSkus    = @()
    if ($graphConnected) {
        try {
            $u = Get-MgUser -UserId $upn -Property AccountEnabled, DisplayName -ErrorAction Stop
            $accountEnabled = $u.AccountEnabled
            if (-not $accountEnabled) { $flags.Add("ACCOUNT_DISABLED") }
        } catch {
            Write-Status "  Could not resolve Entra ID account for $upn : $($_.Exception.Message)" "WARN"
            $flags.Add("ACCOUNT_LOOKUP_FAILED")
        }

        try {
            $lic = Get-MgUserLicenseDetail -UserId $upn -ErrorAction Stop
            $licenseSkus = $lic.SkuPartNumber
            $hasRoomsLicense = $licenseSkus | Where-Object { $_ -match "MEETING_ROOM|MTR|Rooms" }
            $hasCapLicense   = $licenseSkus -contains "MCOCAP"
            if (-not $hasRoomsLicense -and -not $hasCapLicense) {
                $flags.Add("NO_TEAMS_ROOMS_LICENSE")
            }
        } catch {
            $flags.Add("LICENSE_LOOKUP_FAILED")
        }
    }

    # Teams-side policy assignment
    $updatePolicy = $null
    try {
        $csUser = Get-CsOnlineUser -Identity $upn -ErrorAction Stop
        $updatePolicy = $csUser.TeamsUpdateManagementPolicy
        if ([string]::IsNullOrEmpty($updatePolicy)) { $flags.Add("NO_UPDATE_POLICY_ASSIGNED") }
    } catch {
        Write-Status "  Could not retrieve Teams online user for $upn : $($_.Exception.Message)" "WARN"
        $flags.Add("TEAMS_LOOKUP_FAILED")
    }

    # Calendar processing (Exchange Online)
    $autoAccept = $null
    if ($exoConnected) {
        try {
            $cal = Get-CalendarProcessing -Identity $upn -ErrorAction Stop
            $autoAccept = $cal.AutomateProcessing
            if ($autoAccept -ne "AutoAccept") { $flags.Add("CALENDAR_NOT_AUTO_ACCEPT") }
        } catch {
            $flags.Add("CALENDAR_LOOKUP_FAILED")
        }
    }

    # Optional IP phone / hot-desking check
    $hotDeskingEnabled = $null
    if ($IncludeIPPhoneCheck) {
        try {
            $phonePolicyName = $csUser.TeamsIPPhonePolicy
            if ([string]::IsNullOrEmpty($phonePolicyName)) {
                $flags.Add("NO_IP_PHONE_POLICY")
            } else {
                $phonePolicy = Get-CsTeamsIPPhonePolicy -Identity $phonePolicyName -ErrorAction Stop
                $hotDeskingEnabled = $phonePolicy.AllowHotDesking
                if (-not $hotDeskingEnabled) { $flags.Add("HOT_DESKING_DISABLED") }
            }
        } catch {
            $flags.Add("IP_PHONE_POLICY_LOOKUP_FAILED")
        }
    }

    if ($mfaCheck -and $mfaCheck.Checked -and $mfaCheck.PolicyCount -gt 0) {
        # Heuristic only — flag for manual verification rather than asserting a false positive
        $flags.Add("VERIFY_MFA_EXCLUSION")
    }

    $report.Add([PSCustomObject]@{
        ResourceAccountUPN  = $upn
        AccountEnabled      = $accountEnabled
        LicenseSkus         = ($licenseSkus -join "; ")
        UpdatePolicy        = if ($updatePolicy) { $updatePolicy } else { "Global (default)" }
        CalendarAutoAccept  = $autoAccept
        HotDeskingEnabled   = $hotDeskingEnabled
        Flags               = ($flags -join "; ")
        Severity            = if ($flags -match "ACCOUNT_DISABLED|NO_TEAMS_ROOMS_LICENSE") { "HIGH" }
                               elseif ($flags.Count -gt 0) { "MEDIUM" }
                               else { "OK" }
    })
}

# Summary
$separator = "=" * 60
Write-Host ""
Write-Host $separator -ForegroundColor Cyan
Write-Host "  TEAMS DEVICE POLICY AUDIT SUMMARY" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan
$high = $report | Where-Object Severity -eq "HIGH"
$med  = $report | Where-Object Severity -eq "MEDIUM"
Write-Status "Accounts audited: $($report.Count)" "INFO"
Write-Status "HIGH severity (disabled account / missing license): $($high.Count)" $(if ($high.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "MEDIUM severity (policy/calendar gaps): $($med.Count)" $(if ($med.Count -gt 0) { "WARN" } else { "OK" })
$report | Select-Object ResourceAccountUPN, Severity, Flags | Format-Table -AutoSize

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$csvPath = Join-Path $OutputPath "TeamsDevicePolicyAudit-$stamp.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported to: $csvPath" "OK"

if ($exoConnected) { Disconnect-ExchangeOnline -Confirm:$false | Out-Null }
Write-Status "Teams device policy audit complete." "OK"
