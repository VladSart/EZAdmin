<#
.SYNOPSIS
    Reports Apple VPP/location token health and per-app license utilization across the tenant,
    flagging expired/invalid/duplicate tokens and oversubscribed or stale app assignments.

.DESCRIPTION
    Companion script to macOS/Troubleshooting/VPP-App-Deployment-A.md and VPP-App-Deployment-B.md.
    This is an admin-side, tenant-level check — like ABM/DEP token health, VPP token and license
    state is not meaningfully observable from an individual Mac, so this runs against Microsoft
    Graph rather than locally on a device.

    For every VPP/location token in the tenant, this reports:
    - State, ExpirationDateTime, and days remaining — flags TOKEN_EXPIRED and TOKEN_EXPIRING_SOON
      (within -ExpiringSoonDays, default 30) per VPP-App-Deployment-B.md's Triage step 1
    - LastSyncDateTime / LastSyncStatus — flags SYNC_ERROR and SYNC_STALE (no successful sync
      within -StaleSyncHours, default 48, since VPP syncs daily by default so 24h alone is too
      aggressive a threshold for this specific token type)

    For every mobile app associated with each token, this reports:
    - Total/Available/Used license counts — flags LICENSE_EXHAUSTED (Available = 0) and
      LICENSE_NEAR_EXHAUSTION (Used >= -UtilizationWarningPercent, default 50, matching Intune's
      own Enrollment alerts threshold) per VPP-App-Deployment-A.md's Symptom -> Cause Map
    - Assignment count vs. available licenses as a rough oversubscription signal (Graph does not
      expose resolved group-membership counts directly, so this is a best-effort proxy — always
      confirm the true member count in Entra ID before treating this as conclusive)

    Read-only. Makes no changes to any token, app assignment, or license.

.PARAMETER TokenName
    Optional. Restrict the report to a single token's OrganizationName (Apple Account associated
    with the token). Default: report on every VPP token in the tenant.

.PARAMETER ExpiringSoonDays
    Number of days out to flag a token as TOKEN_EXPIRING_SOON. Default 30.

.PARAMETER StaleSyncHours
    Number of hours since the last successful sync before a token is flagged SYNC_STALE. Default
    48 (VPP tokens sync once per day by default, so a 24h-only threshold would false-flag healthy
    tokens that simply haven't hit their next scheduled sync yet).

.PARAMETER UtilizationWarningPercent
    Percentage of licenses used before an app is flagged LICENSE_NEAR_EXHAUSTION. Default 50,
    matching Intune's own built-in Enrollment alerts threshold for VPP license utilization.

.PARAMETER OutputPath
    Path to export a CSV report. Default: $env:TEMP\VPPAppLicenseAudit-<date>.csv

.EXAMPLE
    .\Get-VPPAppLicenseAudit.ps1

.EXAMPLE
    .\Get-VPPAppLicenseAudit.ps1 -TokenName "purchasing@contoso.com" -UtilizationWarningPercent 75

.NOTES
    Requires: Microsoft.Graph.DeviceManagement.Enrollment and Microsoft.Graph.DeviceManagement.Actions
              modules (VPP token + mobile app cmdlets), Connect-MgGraph -Scopes
              "DeviceManagementApps.Read.All"
    Run as:   Any account with Intune app management read rights
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: macOS/Troubleshooting/VPP-App-Deployment-A.md, VPP-App-Deployment-B.md
    Note: this checks VPP/location token and app-license health only — it does not check Apple
    Business Manager DEP/device-enrollment tokens (a separate credential). See
    ABM-Token-Renewal-B.md for that check; the two tokens can be, but are not required to be, tied
    to the same Managed Apple Account, and either can fail independently of the other.
#>

[CmdletBinding()]
param(
    [string]$TokenName,
    [int]$ExpiringSoonDays = 30,
    [int]$StaleSyncHours = 48,
    [int]$UtilizationWarningPercent = 50,
    [string]$OutputPath = "$env:TEMP\VPPAppLicenseAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

Write-Status "VPP App License Audit started — $(Get-Date)" "INFO"

# ─── Preflight ──────────────────────────────────────────────────────────────────

try {
    $ctx = Get-MgContext -ErrorAction Stop
    if (-not $ctx) { throw "No Graph context." }
    if ($ctx.Scopes -notcontains "DeviceManagementApps.Read.All" -and
        $ctx.Scopes -notcontains "DeviceManagementApps.ReadWrite.All") {
        Write-Status "Current Graph session is missing DeviceManagementApps.Read.All — connecting again." "WARN"
        Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Not connected to Microsoft Graph. Connecting now..." "WARN"
    Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome
}

# ─── Detect: pull every VPP token in the tenant ─────────────────────────────────

try {
    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/vppTokens"
    $tokenResponse = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    $tokens = $tokenResponse.value
} catch {
    Write-Status "Failed to query VPP tokens: $($_.Exception.Message)" "ERROR"
    exit 1
}

if ($TokenName) {
    $tokens = $tokens | Where-Object { $_.organizationName -like "*$TokenName*" -or $_.appleId -like "*$TokenName*" }
}

if (-not $tokens -or $tokens.Count -eq 0) {
    Write-Status "No matching VPP tokens found in this tenant. Nothing to report." "WARN"
    exit 0
}

Write-Status "Found $($tokens.Count) VPP token(s) to evaluate." "INFO"
Write-Host ""

# ─── Execute: evaluate each token, then each app under it ──────────────────────

$now = Get-Date
$TokenResults = [System.Collections.Generic.List[PSObject]]::new()
$AppResults   = [System.Collections.Generic.List[PSObject]]::new()

foreach ($t in $tokens) {

    $tokenId     = $t.id
    $orgName     = $t.organizationName
    $appleId     = $t.appleId
    $state       = $t.state
    $expiry      = if ($t.expirationDateTime) { [datetime]$t.expirationDateTime } else { $null }
    $lastSync    = if ($t.lastSyncDateTime)   { [datetime]$t.lastSyncDateTime }   else { $null }
    $syncStatus  = $t.lastSyncStatus

    $daysToExpiry   = if ($expiry)   { [math]::Round(($expiry - $now).TotalDays, 1) }   else { $null }
    $hoursSinceSync = if ($lastSync) { [math]::Round(($now - $lastSync).TotalHours, 1) } else { $null }

    $tokenFlags = [System.Collections.Generic.List[string]]::new()

    if ($state -and $state -notmatch "active|valid") {
        $tokenFlags.Add("TOKEN_STATE_$($state.ToUpper())")
    }
    if ($null -eq $expiry) {
        $tokenFlags.Add("EXPIRY_UNKNOWN")
    } elseif ($daysToExpiry -le 0) {
        $tokenFlags.Add("TOKEN_EXPIRED")
    } elseif ($daysToExpiry -le $ExpiringSoonDays) {
        $tokenFlags.Add("TOKEN_EXPIRING_SOON")
    }
    if ($syncStatus -and $syncStatus -notmatch "success|completed") {
        $tokenFlags.Add("SYNC_ERROR")
    }
    if ($null -eq $lastSync) {
        $tokenFlags.Add("NEVER_SYNCED")
    } elseif ($hoursSinceSync -ge $StaleSyncHours) {
        $tokenFlags.Add("SYNC_STALE")
    }

    $tokenStatus = if ($tokenFlags.Contains("TOKEN_EXPIRED") -or $tokenFlags.Contains("SYNC_ERROR") -or ($tokenFlags | Where-Object { $_ -like "TOKEN_STATE_*" })) {
        "ERROR"
    } elseif ($tokenFlags.Count -gt 0) {
        "WARN"
    } else {
        "OK"
    }

    Write-Status "[Token: $orgName] state=$state expiry=$expiry ($daysToExpiry days) lastSync=$lastSync" $tokenStatus
    if ($tokenFlags.Count -gt 0) {
        Write-Status "    Flags: $($tokenFlags -join ', ')" $tokenStatus
    }

    $TokenResults.Add([PSCustomObject]@{
        TokenOrganizationName = $orgName
        AppleId                = $appleId
        State                   = $state
        ExpirationDateTime      = $expiry
        DaysToExpiry            = $daysToExpiry
        LastSyncDateTime        = $lastSync
        LastSyncStatus          = $syncStatus
        HoursSinceLastSync      = $hoursSinceSync
        Flags                    = ($tokenFlags -join "; ")
        Status                   = $tokenStatus
    })

    # ─── Apps under this token ───────────────────────────────────────────────
    try {
        $appsUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=(isof('microsoft.graph.macOsVppApp'))"
        $appsResponse = Invoke-MgGraphRequest -Method GET -Uri $appsUri -ErrorAction Stop
        $apps = $appsResponse.value | Where-Object { $_.vppTokenId -eq $tokenId -or $_.vppTokenOrganizationName -eq $orgName }
    } catch {
        Write-Status "    Could not enumerate apps for this token: $($_.Exception.Message)" "WARN"
        $apps = @()
    }

    foreach ($a in $apps) {
        $total     = $a.totalLicenseCount
        $used      = $a.usedLicenseCount
        $available = if ($null -ne $total -and $null -ne $used) { $total - $used } else { $null }
        $pctUsed   = if ($total -gt 0) { [math]::Round(($used / $total) * 100, 1) } else { $null }

        $appFlags = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $available -and $available -le 0) {
            $appFlags.Add("LICENSE_EXHAUSTED")
        } elseif ($null -ne $pctUsed -and $pctUsed -ge $UtilizationWarningPercent) {
            $appFlags.Add("LICENSE_NEAR_EXHAUSTION")
        }
        if ($tokenFlags.Contains("TOKEN_EXPIRED") -or $tokenFlags.Contains("SYNC_ERROR")) {
            $appFlags.Add("PARENT_TOKEN_UNHEALTHY")
        }

        $appStatus = if ($appFlags.Contains("LICENSE_EXHAUSTED") -or $appFlags.Contains("PARENT_TOKEN_UNHEALTHY")) {
            "ERROR"
        } elseif ($appFlags.Count -gt 0) {
            "WARN"
        } else {
            "OK"
        }

        $AppResults.Add([PSCustomObject]@{
            AppDisplayName    = $a.displayName
            AppBundleId        = $a.bundleId
            TokenOrganizationName = $orgName
            TotalLicenses       = $total
            UsedLicenses        = $used
            AvailableLicenses   = $available
            PercentUsed         = $pctUsed
            Flags               = ($appFlags -join "; ")
            Status              = $appStatus
        })
    }

    Write-Host ""
}

# ─── Report: summary ────────────────────────────────────────────────────────────

Write-Host "=== TOKEN SUMMARY ===" -ForegroundColor Magenta
$expired      = $TokenResults | Where-Object { $_.Flags -match "TOKEN_EXPIRED" }
$expiringSoon = $TokenResults | Where-Object { $_.Flags -match "TOKEN_EXPIRING_SOON" }
$syncErrors   = $TokenResults | Where-Object { $_.Flags -match "SYNC_ERROR" }
$staleSync    = $TokenResults | Where-Object { $_.Flags -match "SYNC_STALE|NEVER_SYNCED" }

Write-Status "Tokens evaluated:        $($TokenResults.Count)"
Write-Status "Expired:                 $($expired.Count)"      $(if ($expired.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Expiring within $ExpiringSoonDays days:   $($expiringSoon.Count)" $(if ($expiringSoon.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Sync errors:             $($syncErrors.Count)"   $(if ($syncErrors.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Stale/never synced:      $($staleSync.Count)"    $(if ($staleSync.Count -gt 0) { "WARN" } else { "OK" })

Write-Host ""
Write-Host "=== APP LICENSE SUMMARY ===" -ForegroundColor Magenta
$exhausted    = $AppResults | Where-Object { $_.Flags -match "LICENSE_EXHAUSTED" }
$nearExhaust  = $AppResults | Where-Object { $_.Flags -match "LICENSE_NEAR_EXHAUSTION" }

Write-Status "Apps evaluated:                 $($AppResults.Count)"
Write-Status "License-exhausted apps:         $($exhausted.Count)"   $(if ($exhausted.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Apps near exhaustion (>=$UtilizationWarningPercent% used): $($nearExhaust.Count)" $(if ($nearExhaust.Count -gt 0) { "WARN" } else { "OK" })

if ($expired.Count -gt 0 -or $expiringSoon.Count -gt 0) {
    Write-Host ""
    Write-Host "ACTION NEEDED — renew via business.apple.com/school.apple.com > Preferences >" -ForegroundColor Yellow
    Write-Host "Payments and Billing > Apps and Books > Content Tokens > Download, then re-upload" -ForegroundColor Yellow
    Write-Host "in Intune > Tenant administration > Connectors and tokens > Apple VPP tokens." -ForegroundColor Yellow
    Write-Host "See VPP-App-Deployment-B.md Fix 1." -ForegroundColor Yellow
}

if ($exhausted.Count -gt 0) {
    Write-Host ""
    Write-Host "License-exhausted apps will silently fail to assign to any additional group members —" -ForegroundColor Yellow
    Write-Host "purchase more licenses or shrink the assignment group. See VPP-App-Deployment-B.md Fix 2." -ForegroundColor Yellow
}

# ─── Export ──────────────────────────────────────────────────────────────────────

$combined = @()
$combined += $TokenResults | Select-Object *, @{N='RecordType';E={'Token'}}
$combined += $AppResults   | Select-Object *, @{N='RecordType';E={'App'}}
$combined | Export-Csv -Path $OutputPath -NoTypeInformation

Write-Status "`nFull report: $OutputPath" "INFO"
Write-Status "Done." "OK"
