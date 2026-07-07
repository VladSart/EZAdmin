<#
.SYNOPSIS
    Reports Apple Business Manager (ABM)/Apple School Manager (ASM) server and VPP token
    expiration, sync health, and device-count drift for every DEP onboarding setting in the tenant.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/ABM-Token-Renewal-A.md and ABM-Token-Renewal-B.md.
    This is an admin-side, tenant-level check — unlike the other scripts in this folder, ABM/VPP
    token health is not observable from an individual Mac, so this runs against Microsoft Graph
    (beta) rather than locally on a device.

    For every depOnboardingSetting (each Apple Enrollment Program Token entry in Intune) this
    reports:
    - TokenExpirationDateTime and days remaining — flags TOKEN_EXPIRED and TOKEN_EXPIRING_SOON
      (within -ExpiringSoonDays, default 30) per ABM-Token-Renewal-B.md's Triage step 1
    - LastSuccessfulSyncDateTime vs. LastSyncTriggeredDateTime and LastSyncErrorCode — flags
      SYNC_ERROR and SYNC_STALE (no successful sync within -StaleSyncHours, default 24) per
      ABM-Token-Renewal-A.md's Dependency Cascade ("polls ABM every ~15 min")
    - SyncedDeviceCount trend is NOT computed here (Graph does not expose the ABM-side count for
      comparison) — the runbook's Step 4 device-count comparison against business.apple.com must
      still be done manually; this script surfaces SyncedDeviceCount so that manual check is fast
    - TokenType (device enrollment vs. VPP) so both token purposes are reported side by side, per
      ABM-Token-Renewal-A.md's note that device sync and VPP licensing can share or use separate
      tokens

    Read-only. Makes no changes to any token, enrollment profile, or device assignment.

.PARAMETER ExpiringSoonDays
    Number of days out to flag a token as TOKEN_EXPIRING_SOON. Default 30, matching
    ABM-Token-Renewal-B.md's triage threshold and Learning Pointer recommending a 60-day
    calendar reminder (set this higher, e.g. 60, to match that recommendation exactly).

.PARAMETER StaleSyncHours
    Number of hours since the last successful sync before a token is flagged SYNC_STALE.
    Default 24 (ABM syncs roughly every 15 minutes when healthy, so a full day of silence
    is a strong signal something is wrong even before the token's hard expiry).

.PARAMETER OutputPath
    Path to export a CSV report. Default: $env:TEMP\ABMTokenStatus-<date>.csv

.EXAMPLE
    .\Get-ABMTokenStatus.ps1

.EXAMPLE
    .\Get-ABMTokenStatus.ps1 -ExpiringSoonDays 60 -StaleSyncHours 12

.NOTES
    Requires: Microsoft.Graph.Beta.DeviceManagement.Enrollment module,
              Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All"
    Run as:   Any account with Intune enrollment/device configuration read rights
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: macOS/Troubleshooting/ABM-Token-Renewal-A.md, ABM-Token-Renewal-B.md
    Note: this checks the ABM/ASM *server and VPP tokens themselves* — it does not check APNs
    push certificate expiry (a separate, unrelated credential). See MDM-Certificate-Renewal-B.md
    for that check; do not confuse the two when triaging "devices aren't syncing" tickets.
#>

[CmdletBinding()]
param(
    [int]$ExpiringSoonDays = 30,
    [int]$StaleSyncHours = 24,
    [string]$OutputPath = "$env:TEMP\ABMTokenStatus-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

Write-Status "ABM/ASM Token Status check started — $(Get-Date)" "INFO"

# ─── Preflight ──────────────────────────────────────────────────────────────────

try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    if ($ctx.Scopes -notcontains "DeviceManagementServiceConfig.Read.All" -and
        $ctx.Scopes -notcontains "DeviceManagementServiceConfig.ReadWrite.All") {
        Write-Status "Current Graph session is missing DeviceManagementServiceConfig.Read.All — connecting again." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All" -NoWelcome
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Beta.DeviceManagement.Enrollment)) {
    Write-Status "Microsoft.Graph.Beta.DeviceManagement.Enrollment module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Beta.DeviceManagement.Enrollment -Scope CurrentUser" "ERROR"
    exit 1
}

# ─── Detect: pull every DEP onboarding setting (one per Apple Enrollment Program Token) ───────

try {
    $tokens = Get-MgBetaDeviceManagementDepOnboardingSetting -All -ErrorAction Stop
} catch {
    Write-Status "Failed to query DEP onboarding settings: $($_.Exception.Message)" "ERROR"
    exit 1
}

if (-not $tokens -or $tokens.Count -eq 0) {
    Write-Status "No Apple Enrollment Program Tokens found in this tenant. Nothing to report." "WARN"
    exit 0
}

Write-Status "Found $($tokens.Count) Apple Enrollment Program Token(s) to evaluate." "INFO"
Write-Host ""

# ─── Execute: evaluate each token ───────────────────────────────────────────────

$now = Get-Date
$Results = [System.Collections.Generic.List[PSObject]]::new()

foreach ($t in $tokens) {

    $tokenName   = $t.TokenName
    $tokenType   = $t.TokenType
    $appleId     = $t.AppleIdentifier
    $expiry      = $t.TokenExpirationDateTime
    $lastSuccess = $t.LastSuccessfulSyncDateTime
    $lastTrigger = $t.LastSyncTriggeredDateTime
    $syncError   = $t.LastSyncErrorCode
    $deviceCount = $t.SyncedDeviceCount

    $daysToExpiry = if ($expiry) { [math]::Round(($expiry - $now).TotalDays, 1) } else { $null }
    $hoursSinceSync = if ($lastSuccess) { [math]::Round(($now - $lastSuccess).TotalHours, 1) } else { $null }

    $flags = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $expiry) {
        $flags.Add("EXPIRY_UNKNOWN")
    } elseif ($daysToExpiry -le 0) {
        $flags.Add("TOKEN_EXPIRED")
    } elseif ($daysToExpiry -le $ExpiringSoonDays) {
        $flags.Add("TOKEN_EXPIRING_SOON")
    }

    if ($syncError -and $syncError -ne 0) {
        $flags.Add("SYNC_ERROR")
    }

    if ($null -eq $lastSuccess) {
        $flags.Add("NEVER_SYNCED")
    } elseif ($hoursSinceSync -ge $StaleSyncHours) {
        $flags.Add("SYNC_STALE")
    }

    $status = if ($flags.Contains("TOKEN_EXPIRED") -or $flags.Contains("SYNC_ERROR")) {
        "ERROR"
    } elseif ($flags.Count -gt 0) {
        "WARN"
    } else {
        "OK"
    }

    Write-Status "[$tokenName] type=$tokenType expiry=$expiry ($daysToExpiry days) lastSync=$lastSuccess devices=$deviceCount" $status
    if ($flags.Count -gt 0) {
        Write-Status "    Flags: $($flags -join ', ')" $status
    }

    $Results.Add([PSCustomObject]@{
        TokenName                 = $tokenName
        TokenType                 = $tokenType
        AppleIdentifier           = $appleId
        TokenExpirationDateTime   = $expiry
        DaysToExpiry              = $daysToExpiry
        LastSuccessfulSyncDateTime = $lastSuccess
        LastSyncTriggeredDateTime = $lastTrigger
        HoursSinceLastSuccessSync = $hoursSinceSync
        LastSyncErrorCode         = $syncError
        SyncedDeviceCount         = $deviceCount
        Flags                     = ($flags -join "; ")
        Status                    = $status
    })
}

# ─── Report: summary ────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Magenta

$expired      = $Results | Where-Object { $_.Flags -match "TOKEN_EXPIRED" }
$expiringSoon = $Results | Where-Object { $_.Flags -match "TOKEN_EXPIRING_SOON" }
$syncErrors   = $Results | Where-Object { $_.Flags -match "SYNC_ERROR" }
$staleSync    = $Results | Where-Object { $_.Flags -match "SYNC_STALE|NEVER_SYNCED" }

Write-Status "Tokens evaluated:        $($Results.Count)"
Write-Status "Expired:                 $($expired.Count)"      $(if ($expired.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Expiring within $ExpiringSoonDays days:   $($expiringSoon.Count)" $(if ($expiringSoon.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Sync errors:             $($syncErrors.Count)"   $(if ($syncErrors.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Stale/never synced:      $($staleSync.Count)"    $(if ($staleSync.Count -gt 0) { "WARN" } else { "OK" })

if ($expired.Count -gt 0 -or $expiringSoon.Count -gt 0) {
    Write-Host ""
    Write-Host "ACTION NEEDED — renew via business.apple.com > Preferences > MDM Server Assignment," -ForegroundColor Yellow
    Write-Host "then Intune > Devices > Enrollment > Apple > Enrollment Program Tokens > Renew Token (NOT Add)." -ForegroundColor Yellow
    Write-Host "See ABM-Token-Renewal-B.md Fix 1 (device tokens) / Fix 2 (VPP tokens)." -ForegroundColor Yellow
}

if ($syncErrors.Count -gt 0 -or $staleSync.Count -gt 0) {
    Write-Host ""
    Write-Host "Also compare SyncedDeviceCount above against the device count in business.apple.com" -ForegroundColor Yellow
    Write-Host "(filtered by MDM server assignment) — a gap confirms sync degradation per Diagnosis Step 4." -ForegroundColor Yellow
}

# ─── Export ──────────────────────────────────────────────────────────────────────

$Results | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "`nFull report: $OutputPath" "INFO"
Write-Status "Done." "OK"
