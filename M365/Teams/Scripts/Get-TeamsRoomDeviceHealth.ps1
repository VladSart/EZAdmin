<#
.SYNOPSIS
    Audits Microsoft Teams Rooms (MTR) resource account health across the tenant —
    account state, licensing, sign-in failures, and stale/inactive rooms.

.DESCRIPTION
    Connects to Microsoft Graph and, for each Teams Rooms resource account (or a
    single specified room), reports:
      - Account enabled/disabled state
      - Password expiration policy (rooms should use DisablePasswordExpiration)
      - Teams Rooms Basic/Pro license assignment and license errors
      - Recent sign-in failures (last 24h by default) with error codes
      - Last interactive/non-interactive sign-in timestamp (staleness detection)
      - Whether the account sits in a Conditional Access exclusion group, if one
        is supplied via -CAExclusionGroupId
    Designed to catch the two most common MTR outages: expired resource account
    passwords and license assignment errors that silently break sign-in.
    Exports a CSV report. Read-only — does not touch account state or licensing.

.PARAMETER RoomUPN
    Check a single room resource account by UPN. If omitted, scans all accounts
    found via -RoomFilter.

.PARAMETER RoomFilter
    Graph filter fragment used to identify room resource accounts when -RoomUPN
    is not specified. Default matches a common naming convention; adjust to your
    tenant (e.g. "startswith(displayName,'Room -')" or a dedicated group).

.PARAMETER CAExclusionGroupId
    Object ID of the Conditional Access exclusion group used for MTR accounts.
    If supplied, each room's membership is checked and flagged if missing.

.PARAMETER SignInLookbackHours
    Hours of sign-in log history to scan for failures. Default: 24.

.PARAMETER OutputPath
    Where to save the CSV report. Default: C:\Temp\TeamsRoom-Health-<date>.csv

.EXAMPLE
    .\Get-TeamsRoomDeviceHealth.ps1 -RoomUPN "room-3rdfloor@contoso.com"

.EXAMPLE
    .\Get-TeamsRoomDeviceHealth.ps1 -RoomFilter "startswith(displayName,'MTR-')" -CAExclusionGroupId "11111111-2222-3333-4444-555555555555"

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Reports, Microsoft.Graph.Groups modules
    Scopes:   User.Read.All, AuditLog.Read.All, Group.Read.All
    Run as:   Account with Global Reader or Teams Device Administrator role
    Safe:     Read-only. No resource account, license, or group membership is modified.
#>

[CmdletBinding()]
param(
    [string]$RoomUPN = "",
    [string]$RoomFilter = "startswith(displayName,'Room') or startswith(displayName,'MTR')",
    [string]$CAExclusionGroupId = "",
    [int]$SignInLookbackHours = 24,
    [string]$OutputPath = "C:\Temp\TeamsRoom-Health-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Write-Host "`n=== Teams Rooms Device Health Audit ===" -ForegroundColor Cyan
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

# ─────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────
$requiredModules = @("Microsoft.Graph.Users", "Microsoft.Graph.Reports")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod module not found. Install with: Install-Module $mod -Scope CurrentUser" "ERROR"
        exit 1
    }
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "User.Read.All", "AuditLog.Read.All", "Group.Read.All" -NoWelcome
    } else {
        Write-Status "Using existing Graph session: $($context.Account)" "OK"
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $_" "ERROR"
    exit 1
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Room, [string]$Category, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Room     = $Room
        Category = $Category
        Status   = $Status
        Detail   = $Detail
    })
    Write-Status "$Room | $Category — $Detail" $Status
}

# ─────────────────────────────────────────────
# 1. RESOLVE ROOM ACCOUNTS
# ─────────────────────────────────────────────
Write-Host "--- Resolving Room Resource Accounts ---" -ForegroundColor Cyan

$roomProps = "id,displayName,userPrincipalName,accountEnabled,passwordPolicies,assignedLicenses,signInActivity,usageLocation"

if ($RoomUPN -ne "") {
    try {
        $rooms = @(Get-MgUser -UserId $RoomUPN -Property $roomProps -ErrorAction Stop)
    } catch {
        Write-Status "Could not find user '$RoomUPN': $_" "ERROR"
        exit 1
    }
} else {
    try {
        $rooms = @(Get-MgUser -Filter $RoomFilter -Property $roomProps -All -ErrorAction Stop)
    } catch {
        Write-Status "Filter query failed — check -RoomFilter syntax: $_" "ERROR"
        exit 1
    }
}

if ($rooms.Count -eq 0) {
    Write-Status "No room resource accounts matched. Adjust -RoomUPN or -RoomFilter." "WARN"
    exit 0
}

Write-Status "Resolved $($rooms.Count) room account(s)" "OK"

# CA exclusion group membership (optional)
$exclusionMembers = @()
if ($CAExclusionGroupId -ne "") {
    try {
        $exclusionMembers = (Get-MgGroupMember -GroupId $CAExclusionGroupId -All | Select-Object -ExpandProperty Id)
        Write-Status "Loaded CA exclusion group membership ($($exclusionMembers.Count) members)" "OK"
    } catch {
        Write-Status "Could not read CA exclusion group '$CAExclusionGroupId': $_" "WARN"
    }
}

# ─────────────────────────────────────────────
# 2. PER-ROOM CHECKS
# ─────────────────────────────────────────────
Write-Host "`n--- Per-Room Checks ---" -ForegroundColor Cyan

$sinceTime = (Get-Date).ToUniversalTime().AddHours(-$SignInLookbackHours).ToString("yyyy-MM-ddTHH:mm:ssZ")

foreach ($room in $rooms) {
    $name = $room.DisplayName
    $upn  = $room.UserPrincipalName

    # 2.1 Account enabled
    if ($room.AccountEnabled) {
        Add-Result $name "Account State" "OK" "Account enabled"
    } else {
        Add-Result $name "Account State" "ERROR" "Account DISABLED — room will not be able to sign in or join meetings"
    }

    # 2.2 Password expiration policy
    $pwPolicies = $room.PasswordPolicies
    if ($pwPolicies -match "DisablePasswordExpiration") {
        Add-Result $name "Password Policy" "OK" "Password expiration disabled (correct for unattended resource accounts)"
    } else {
        Add-Result $name "Password Policy" "WARN" "Password expiration NOT disabled — this account can lock itself out silently when the password expires. Set DisablePasswordExpiration."
    }

    # 2.3 Usage location (required for license assignment)
    if ([string]::IsNullOrEmpty($room.UsageLocation)) {
        Add-Result $name "Usage Location" "ERROR" "No UsageLocation set — license assignment will fail or has silently failed"
    } else {
        Add-Result $name "Usage Location" "OK" "UsageLocation: $($room.UsageLocation)"
    }

    # 2.4 License assignment
    try {
        $licenseDetails = Get-MgUserLicenseDetail -UserId $room.Id -ErrorAction Stop
        $mtrLicense = $licenseDetails | Where-Object { $_.SkuPartNumber -match "MTR|MEETING_ROOM|Teams_Room" }
        if ($mtrLicense) {
            Add-Result $name "Licensing" "OK" "MTR license assigned: $($mtrLicense.SkuPartNumber -join ', ')"
        } elseif ($licenseDetails.Count -gt 0) {
            Add-Result $name "Licensing" "WARN" "Licensed but no recognizable MTR SKU found: $($licenseDetails.SkuPartNumber -join ', ')"
        } else {
            Add-Result $name "Licensing" "ERROR" "No licenses assigned — room account cannot join meetings without Teams Rooms Basic or Pro"
        }
    } catch {
        Add-Result $name "Licensing" "WARN" "Could not retrieve license details: $_"
    }

    # Check for license assignment errors (group-based licensing failures)
    try {
        $fullUser = Get-MgUser -UserId $room.Id -Property "licenseAssignmentStates" -ErrorAction Stop
        $errored = $fullUser.LicenseAssignmentStates | Where-Object { $_.State -eq "Error" }
        if ($errored) {
            foreach ($err in $errored) {
                Add-Result $name "License Error" "ERROR" "SkuId $($err.SkuId) assignment error: $($err.Error) (likely a group-based licensing conflict or missing service plan dependency)"
            }
        }
    } catch {
        Add-Result $name "License Error" "SKIP" "Could not check licenseAssignmentStates: $_"
    }

    # 2.5 Sign-in failures (lookback window)
    try {
        $filter = "userPrincipalName eq '$upn' and status/errorCode ne 0 and createdDateTime ge $sinceTime"
        $failures = Get-MgAuditLogSignIn -Filter $filter -Top 20 -ErrorAction Stop
        if ($failures -and $failures.Count -gt 0) {
            $topError = $failures | Group-Object -Property { $_.Status.ErrorCode } | Sort-Object Count -Descending | Select-Object -First 1
            Add-Result $name "Sign-In Failures" "WARN" "$($failures.Count) failed sign-in(s) in last ${SignInLookbackHours}h. Most common error code: $($topError.Name) x$($topError.Count)"
        } else {
            Add-Result $name "Sign-In Failures" "OK" "No sign-in failures in last ${SignInLookbackHours}h"
        }
    } catch {
        Add-Result $name "Sign-In Failures" "SKIP" "Could not query sign-in logs (requires AuditLog.Read.All): $_"
    }

    # 2.6 Staleness — last sign-in activity
    $lastSignIn = $room.SignInActivity.LastSignInDateTime
    if ($lastSignIn) {
        $daysSince = [math]::Round(((Get-Date).ToUniversalTime() - $lastSignIn).TotalDays, 1)
        if ($daysSince -gt 7) {
            Add-Result $name "Activity" "WARN" "No sign-in activity in $daysSince days — room device may be offline or unplugged"
        } else {
            Add-Result $name "Activity" "OK" "Last sign-in: $($lastSignIn.ToString('yyyy-MM-dd HH:mm')) UTC ($daysSince days ago)"
        }
    } else {
        Add-Result $name "Activity" "WARN" "No sign-in activity recorded — room may have never completed setup"
    }

    # 2.7 CA exclusion group membership
    if ($CAExclusionGroupId -ne "") {
        if ($exclusionMembers -contains $room.Id) {
            Add-Result $name "CA Exclusion" "OK" "Room is a member of the specified CA exclusion group"
        } else {
            Add-Result $name "CA Exclusion" "WARN" "Room is NOT in the CA exclusion group — verify this is intentional; MFA-requiring CA policies will block unattended sign-in"
        }
    }
}

# ─────────────────────────────────────────────
# REPORT
# ─────────────────────────────────────────────
Write-Host "`n--- Generating Report ---" -ForegroundColor Cyan

$okCount    = ($results | Where-Object {$_.Status -eq "OK"}).Count
$warnCount  = ($results | Where-Object {$_.Status -eq "WARN"}).Count
$errorCount = ($results | Where-Object {$_.Status -eq "ERROR"}).Count
$skipCount  = ($results | Where-Object {$_.Status -eq "SKIP"}).Count

if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Status "Report saved to: $OutputPath" "OK"
Write-Host ""
Write-Host "=== Summary: OK: $okCount  WARN: $warnCount  ERROR: $errorCount  SKIP: $skipCount ===" -ForegroundColor Cyan
Write-Host "Rooms audited: $($rooms.Count)" -ForegroundColor Cyan
