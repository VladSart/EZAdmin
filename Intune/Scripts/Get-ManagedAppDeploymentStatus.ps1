<#
.SYNOPSIS
    Diagnoses Intune Managed App (Win32/LOB/VPP) deployment health — local IME state
    plus fleet-wide install status and Apple VPP token health via Graph.

.DESCRIPTION
    Companion diagnostic for Intune/Troubleshooting/Managed-Apps-B.md and -A.md, which
    covers app deployment (Win32, LOB, Store, VPP) as distinct from App Protection/MAM
    policy enforcement (see Get-AppProtectionCoverageReport.ps1 for that side).

    Local mode (run ON the affected Windows endpoint):
      - Checks the IntuneManagementExtension service state — Managed-Apps-B.md Fix 1
        identifies a stopped/crashed IME as the top cause of Win32 apps stuck "Pending"
      - Surfaces the last N lines of the IME log filtered to install/detection/exit-code
        activity, so an engineer doesn't have to manually grep a multi-MB log file
      - Extracts the most recent ExitCode per app install attempt (0/3010 = success,
        1603 and others = failure) per Managed-Apps-A.md Phase 3 guidance

    Fleet mode (run from an admin workstation with Graph):
      - Reports Win32 app device-install status per app, bucketing into Installed /
        Failed / Pending / NotApplicable, and flags apps with a failure rate above
        -FailureRateThreshold (default 15%) as HIGH_FAILURE_RATE — often a detection
        rule mismatch per Managed-Apps-A.md Fix 2 rather than N individual device issues
      - Checks Apple VPP token health (state, expiry, remaining licenses) and flags
        EXPIRING_SOON (<30 days, per Managed-Apps-A.md's VPP token Learning Pointer)
        and LICENSES_EXHAUSTED

    This script makes no install, retry, or policy changes — it is a read-only
    diagnostic tool only.

.PARAMETER AppId
    Intune mobile app ID (Win32/LOB) to pull fleet-wide device install status for.

.PARAMETER FailureRateThreshold
    Fraction (0.0-1.0) of failed installs against total attempts before an app is
    flagged HIGH_FAILURE_RATE. Default: 0.15 (15%).

.PARAMETER CheckVppTokens
    Switch. When set, retrieves and evaluates all Apple VPP token health via Graph.

.PARAMETER VppExpiryWarningDays
    Days before VPP token expiry to flag EXPIRING_SOON. Default: 30.

.PARAMETER LocalLogTail
    Number of matching lines to pull from the local IME log. Default: 100.

.PARAMETER OutputPath
    Folder to write CSV report(s) to. Default: current directory.

.EXAMPLE
    .\Get-ManagedAppDeploymentStatus.ps1
    Runs the local IME service/log check only (safe default on any Windows endpoint).

.EXAMPLE
    .\Get-ManagedAppDeploymentStatus.ps1 -AppId "<intuneAppId>" -FailureRateThreshold 0.10
    Pulls fleet-wide install status for one Win32/LOB app with a stricter failure threshold.

.EXAMPLE
    .\Get-ManagedAppDeploymentStatus.ps1 -CheckVppTokens
    Checks Apple VPP token health tenant-wide without touching a specific app.

.NOTES
    Requires (local mode): Windows, IntuneManagementExtension present (or absent, which
                           itself is diagnostic information)
    Requires (fleet mode): Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
    Scopes (fleet mode):   DeviceManagementApps.Read.All, DeviceManagementManagedDevices.Read.All
    Safe/Unsafe:           Fully read-only. No app reassignment, retry, or token renewal
                           is performed — this reports state only.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AppId,

    [Parameter(Mandatory = $false)]
    [double]$FailureRateThreshold = 0.15,

    [Parameter(Mandatory = $false)]
    [switch]$CheckVppTokens,

    [Parameter(Mandatory = $false)]
    [int]$VppExpiryWarningDays = 30,

    [Parameter(Mandatory = $false)]
    [int]$LocalLogTail = 100,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------------------------------------------------------------------------
# LOCAL MODE — IME service + log health (always runs; safe on any Windows box)
# ---------------------------------------------------------------------------
Write-Status "=== Local IME Health (Win32 App Deployment Agent) ===" "INFO"

$imeService = Get-Service -Name "IntuneManagementExtension" -ErrorAction SilentlyContinue
if (-not $imeService) {
    Write-Status "IntuneManagementExtension service not found — either not a managed Windows device, or no Win32/PowerShell script/Remediation has ever been assigned (IME installs on first assignment)." "WARN"
}
else {
    if ($imeService.Status -eq 'Running') {
        Write-Status "IME service is Running (StartType: $($imeService.StartType))." "OK"
    }
    else {
        Write-Status "IME service is '$($imeService.Status)' — this is the top cause of Win32 apps stuck 'Pending' per Managed-Apps-B.md Fix 1. Restart-Service IntuneManagementExtension -Force" "ERROR"
    }

    $logPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    if (Test-Path $logPath) {
        Write-Status "Scanning IME log for install/detection/exit-code activity (last $LocalLogTail matching lines)..."
        $matches = Get-Content $logPath -ErrorAction SilentlyContinue |
            Select-String -Pattern "ExitCode|DetectionRule|Applicability|DownloadComplete|Win32App" |
            Select-Object -Last $LocalLogTail

        if ($matches) {
            $exitCodeLines = $matches | Where-Object { $_ -match "ExitCode" }
            $failedExits = $exitCodeLines | Where-Object { $_ -notmatch "ExitCode:\s*0\b" -and $_ -notmatch "ExitCode:\s*3010\b" }

            Write-Status "Found $($exitCodeLines.Count) exit-code line(s) in recent log activity; $($failedExits.Count) look like non-success codes." $(if ($failedExits.Count -gt 0) { "WARN" } else { "OK" })
            if ($failedExits.Count -gt 0) {
                Write-Status "Non-success exit codes (most recent last):" "WARN"
                $failedExits | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                Write-Status "Exit code 1603 = generic MSI failure; reproduce manually as SYSTEM (PsExec -s -i) per Managed-Apps-A.md Phase 3." "INFO"
            }
        }
        else {
            Write-Status "No recent install/detection activity found in the log — no Win32 app work has run recently on this device." "INFO"
        }
    }
    else {
        Write-Status "IME log not found at expected path: $logPath" "WARN"
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# FLEET MODE — Win32/LOB app install status via Graph
# ---------------------------------------------------------------------------
if ($AppId) {
    Write-Status "=== Fleet Install Status (App: $AppId) ===" "INFO"

    try {
        $context = Get-MgContext
        if (-not $context) {
            Write-Status "Not connected. Connecting with required scopes..." "WARN"
            Connect-MgGraph -Scopes "DeviceManagementApps.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome
        }
        else {
            Write-Status "Connected as $($context.Account)" "OK"
        }
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        throw
    }

    try {
        $deviceStatuses = Get-MgDeviceAppManagementMobileAppDeviceStatus -MobileAppId $AppId -All
    }
    catch {
        Write-Status "Failed to retrieve device install statuses for app '$AppId': $($_.Exception.Message)" "ERROR"
        throw
    }

    $report = $deviceStatuses | ForEach-Object {
        [PSCustomObject]@{
            DeviceName       = $_.DeviceName
            UserName         = $_.UserName
            InstallState     = $_.InstallState
            InstallStateDetail = $_.InstallStateDetail
            ErrorCode        = $_.ErrorCode
            LastSyncDateTime = $_.LastSyncDateTime
        }
    }

    $reportFile = Join-Path $OutputPath "ManagedAppInstallStatus-$AppId-$timestamp.csv"
    $report | Sort-Object InstallState, DeviceName | Export-Csv -Path $reportFile -NoTypeInformation

    $total = @($report).Count
    $failed = @($report | Where-Object { $_.InstallState -eq 'failed' }).Count
    $installed = @($report | Where-Object { $_.InstallState -eq 'installed' }).Count
    $pending = @($report | Where-Object { $_.InstallState -in @('notInstalled', 'downloading', 'pending') }).Count
    $failureRate = if ($total -gt 0) { $failed / $total } else { 0 }

    Write-Status "Total device targets: $total" "INFO"
    Write-Status "Installed: $installed | Failed: $failed | Pending/NotInstalled: $pending" "INFO"

    if ($failureRate -ge $FailureRateThreshold) {
        Write-Status ("HIGH_FAILURE_RATE: {0:P0} of installs failed (threshold: {1:P0}). This pattern points to a detection rule mismatch or install-command issue affecting the whole population, not isolated device problems — see Managed-Apps-A.md Fix 2." -f $failureRate, $FailureRateThreshold) "ERROR"
    }
    else {
        Write-Status ("Failure rate {0:P0} is below threshold ({1:P0})." -f $failureRate, $FailureRateThreshold) "OK"
    }

    Write-Status "Fleet report exported to: $reportFile" "OK"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# VPP TOKEN HEALTH
# ---------------------------------------------------------------------------
if ($CheckVppTokens) {
    Write-Status "=== Apple VPP Token Health ===" "INFO"

    try {
        $context = Get-MgContext
        if (-not $context) {
            Write-Status "Not connected. Connecting with required scopes..." "WARN"
            Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome
        }
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        throw
    }

    try {
        $tokens = Get-MgDeviceAppManagementVppToken -All
    }
    catch {
        Write-Status "Failed to retrieve VPP tokens: $($_.Exception.Message)" "ERROR"
        throw
    }

    if (-not $tokens -or @($tokens).Count -eq 0) {
        Write-Status "No Apple VPP tokens found in this tenant." "INFO"
    }
    else {
        $vppReport = $tokens | ForEach-Object {
            $expiry = $_.ExpirationDateTime
            $daysToExpiry = if ($expiry) { ($expiry - (Get-Date)).Days } else { $null }
            $flags = New-Object System.Collections.Generic.List[string]

            if ($_.State -ne 'valid' -and $_.AdditionalProperties.ContainsKey('state')) {
                $flags.Add("STATE_$($_.AdditionalProperties['state'])".ToUpper())
            }
            if ($null -ne $daysToExpiry -and $daysToExpiry -le $VppExpiryWarningDays) { $flags.Add("EXPIRING_SOON") }
            if ($_.AdditionalProperties.ContainsKey('countOfAppsWithAvailableLicenses') -and
                [int]$_.AdditionalProperties['countOfAppsWithAvailableLicenses'] -eq 0) {
                $flags.Add("LICENSES_EXHAUSTED")
            }

            [PSCustomObject]@{
                OrganizationName = $_.OrganizationName
                ExpirationDateTime = $expiry
                DaysToExpiry     = $daysToExpiry
                LastSyncDateTime = $_.LastSyncDateTime
                Flags            = ($flags -join "; ")
            }
        }

        $vppFile = Join-Path $OutputPath "VppTokenHealth-$timestamp.csv"
        $vppReport | Export-Csv -Path $vppFile -NoTypeInformation

        foreach ($t in $vppReport) {
            $status = if ($t.Flags) { "WARN" } else { "OK" }
            Write-Status "$($t.OrganizationName): expires $($t.ExpirationDateTime) ($($t.DaysToExpiry) days) - $($t.Flags)" $status
        }
        Write-Status "VPP token report exported to: $vppFile" "OK"
    }
}

if (-not $AppId -and -not $CheckVppTokens) {
    Write-Status "No -AppId or -CheckVppTokens supplied — ran local IME check only. Add -AppId <id> for fleet install status, or -CheckVppTokens for Apple VPP health." "INFO"
}
