<#
.SYNOPSIS
    Diagnoses a stuck or timed-out Windows Autopilot Enrollment Status Page (ESP) on the local device.

.DESCRIPTION
    Device-local diagnostic covering every layer of the ESP dependency chain described in
    Autopilot/Troubleshooting/ESP-Stuck-A.md: ESP/Autopilot event logs, the Intune Management
    Extension (IME) app-install log, MDM enrollment event log, ESP registry state
    (EnrollmentStatusTracking + DeviceContext), Win32 app tracking registry, and reachability of
    the ESP-critical network endpoints. Also flags the Hybrid Join connector dependency when the
    device is (or is attempting to be) Hybrid Azure AD joined.

    Does NOT modify ESP state, skip ESP, or change any app assignment — this is read-only evidence
    collection and interpretation. For remediation (Fix 1-4), see ESP-Stuck-B.md / ESP-Stuck-A.md.

    Run this on the affected device itself — either post-failure at the desktop, or via an admin
    command prompt reachable from the ESP error screen (Ctrl+Shift+F3 / task manager new task).

.PARAMETER OutputPath
    Folder to write the CSV/report evidence to. Defaults to a timestamped folder under $env:TEMP.

.PARAMETER SkipNetworkTest
    Skip the live network reachability test against ESP endpoints (useful if already confirmed,
    or if running from a locked-down context where outbound test connections are undesirable).

.EXAMPLE
    .\Get-ESPDeploymentStatus.ps1

    Runs the full diagnostic and writes evidence + a console summary.

.EXAMPLE
    .\Get-ESPDeploymentStatus.ps1 -OutputPath "C:\Temp\ESPDiag" -SkipNetworkTest

.NOTES
    Requires: Local admin to read some registry/event log paths. No Graph/M365 connection needed —
    entirely device-local. Safe to run on a production device; makes no changes.
    Companion runbook: Autopilot/Troubleshooting/ESP-Stuck-A.md and ESP-Stuck-B.md
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:TEMP\ESP_Diag_$(Get-Date -Format yyyyMMdd_HHmmss)",
    [switch]$SkipNetworkTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting ESP deployment status diagnostic on $env:COMPUTERNAME"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param([string]$Area, [string]$Flag, [string]$Detail)
    $findings.Add([PSCustomObject]@{ Area = $Area; Flag = $Flag; Detail = $Detail })
}

# ---------------------------------------------------------------------------
# 1. ESP / Autopilot event logs
# ---------------------------------------------------------------------------
Write-Status "Reading ESP/Autopilot event logs..."
$espLogs = @(
    "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/AutoPilot",
    "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Diagnostics",
    "Microsoft-Windows-Provisioning-Diagnostics-Provider/AutoPilot",
    "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin"
)
$allEvents = @()
foreach ($log in $espLogs) {
    $events = Get-WinEvent -LogName $log -MaxEvents 100 -ErrorAction SilentlyContinue
    if ($events) {
        $allEvents += $events | Select-Object TimeCreated, LevelDisplayName, Id, LogName, Message
    }
}
if ($allEvents) {
    $allEvents | Sort-Object TimeCreated -Descending |
        Export-Csv "$OutputPath\ESP_EventLogs.csv" -NoTypeInformation
    $errCount = ($allEvents | Where-Object { $_.LevelDisplayName -eq "Error" }).Count
    if ($errCount -gt 0) {
        Add-Finding "EventLog" "ESP_ERRORS_FOUND" "$errCount error-level ESP/enrollment events found — see ESP_EventLogs.csv"
        Write-Status "$errCount error-level ESP events found" "WARN"
    } else {
        Write-Status "No error-level ESP events found" "OK"
    }
} else {
    Add-Finding "EventLog" "NO_ESP_LOGS" "No ESP/Autopilot diagnostic events present — device may not have gone through ESP recently"
    Write-Status "No ESP/Autopilot event log entries found" "WARN"
}

# ---------------------------------------------------------------------------
# 2. Intune Management Extension (IME) log — app install failures
# ---------------------------------------------------------------------------
Write-Status "Checking IME log for app install failures..."
$imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLog) {
    $imeTail = Get-Content $imeLog -Tail 2000
    $imeIssues = $imeTail | Where-Object { $_ -match "error|fail|timeout|exception|0x8" }
    if ($imeIssues) {
        $imeIssues | Select-Object -Last 100 | Out-File "$OutputPath\IME_Issues_Tail.log"
        Add-Finding "IME" "APP_INSTALL_ISSUES" "$($imeIssues.Count) error/timeout lines found in IME log — see IME_Issues_Tail.log"
        Write-Status "$($imeIssues.Count) potential app-install issue lines in IME log" "WARN"
    } else {
        Write-Status "No error/timeout patterns found in IME log tail" "OK"
    }
    $imeTail | Select-Object -Last 300 | Out-File "$OutputPath\IME_Log_Tail300.log"
} else {
    Add-Finding "IME" "IME_LOG_MISSING" "IntuneManagementExtension.log not found — IME may not have started, or no Win32 apps are targeted"
    Write-Status "IME log not found at expected path" "WARN"
}

# ---------------------------------------------------------------------------
# 3. ESP registry state
# ---------------------------------------------------------------------------
Write-Status "Reading ESP registry state..."
$espTrackingBase = "HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking"
$deviceContextBase = "HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\DeviceContext"

if (Test-Path $espTrackingBase) {
    $trackingDump = Get-ChildItem $espTrackingBase -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        [PSCustomObject]@{ RegPath = $_.PSPath -replace ".*EnrollmentStatusTracking\\", ""; Properties = ($props | Out-String).Trim() }
    }
    $trackingDump | Export-Csv "$OutputPath\ESP_Registry_Tracking.csv" -NoTypeInformation
    Write-Status "ESP tracking registry captured ($($trackingDump.Count) keys)" "OK"
} else {
    Add-Finding "Registry" "NO_ESP_TRACKING_KEY" "EnrollmentStatusTracking registry key not present — ESP may not have run on this device, or already cleaned up post-completion"
    Write-Status "EnrollmentStatusTracking registry key not found" "WARN"
}

if (Test-Path $deviceContextBase) {
    Get-ItemProperty $deviceContextBase -ErrorAction SilentlyContinue |
        Select-Object * -ExcludeProperty PS* |
        Out-File "$OutputPath\ESP_DeviceContext.txt"
}

# ---------------------------------------------------------------------------
# 4. Win32 app tracking registry (ESP-blocking app state)
# ---------------------------------------------------------------------------
Write-Status "Checking Win32 app registry state..."
$win32Base = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps"
if (Test-Path $win32Base) {
    $win32Apps = Get-ChildItem $win32Base -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.PSObject.Properties.Name -contains "ResultCode") {
            [PSCustomObject]@{
                RegPath    = ($_.PSPath -split "\\" | Select-Object -Last 4) -join "\"
                ResultCode = $p.ResultCode
                ErrorCode  = $p.ErrorCode
            }
        }
    } | Where-Object { $_ }
    if ($win32Apps) {
        $win32Apps | Export-Csv "$OutputPath\Win32App_State.csv" -NoTypeInformation
        $failedApps = $win32Apps | Where-Object { $_.ErrorCode -and $_.ErrorCode -ne 0 }
        if ($failedApps) {
            Add-Finding "Win32Apps" "APP_INSTALL_ERROR_CODE" "$($failedApps.Count) Win32 app(s) with non-zero ErrorCode — see Win32App_State.csv"
            Write-Status "$($failedApps.Count) Win32 apps show a non-zero error code" "WARN"
        } else {
            Write-Status "No Win32 apps with non-zero error codes" "OK"
        }
    }
} else {
    Write-Status "No Win32Apps registry key found (no Win32 apps targeted, or IME never ran)" "INFO"
}

# ---------------------------------------------------------------------------
# 5. Device join state (Hybrid Join dependency check)
# ---------------------------------------------------------------------------
Write-Status "Checking device join state (dsregcmd)..."
$dsreg = dsregcmd /status 2>&1
$dsreg | Out-File "$OutputPath\DsregCmd_Status.txt"
$dsregText = $dsreg | Out-String
if ($dsregText -match "DomainJoined\s*:\s*YES") {
    if ($dsregText -notmatch "AzureAdJoined\s*:\s*YES") {
        Add-Finding "HybridJoin" "HYBRID_JOIN_NOT_COMPLETE" "Device is domain-joined but not yet Azure AD joined — check Domain Join connector and Entra Connect sync (see EntraID/Scripts/Get-HybridJoinDiagnostics.ps1)"
        Write-Status "Domain-joined but AzureAdJoined is not YES — Hybrid Join incomplete" "WARN"
    } else {
        Write-Status "Hybrid Azure AD Join appears complete" "OK"
    }
}

# ---------------------------------------------------------------------------
# 6. Network connectivity to ESP-critical endpoints
# ---------------------------------------------------------------------------
if (-not $SkipNetworkTest) {
    Write-Status "Testing network connectivity to ESP endpoints..."
    $espUrls = @(
        "manage.microsoft.com",
        "enterpriseregistration.windows.net",
        "login.microsoftonline.com",
        "portal.manage.microsoft.com",
        "dl.delivery.mp.microsoft.com",
        "config.office.com"
    )
    $netResults = foreach ($url in $espUrls) {
        $r = Test-NetConnection -ComputerName $url -Port 443 -WarningAction SilentlyContinue
        [PSCustomObject]@{
            URL       = $url
            Reachable = $r.TcpTestSucceeded
        }
    }
    $netResults | Export-Csv "$OutputPath\Network_ESP_URLs.csv" -NoTypeInformation
    $unreachable = $netResults | Where-Object { -not $_.Reachable }
    if ($unreachable) {
        Add-Finding "Network" "ESP_ENDPOINT_UNREACHABLE" "$($unreachable.Count) ESP endpoint(s) unreachable on TCP/443: $($unreachable.URL -join ', ')"
        Write-Status "$($unreachable.Count) ESP endpoints unreachable" "ERROR"
    } else {
        Write-Status "All tested ESP endpoints reachable on TCP/443" "OK"
    }
} else {
    Write-Status "Network test skipped (-SkipNetworkTest)" "INFO"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$findings | Export-Csv "$OutputPath\Findings_Summary.csv" -NoTypeInformation

Write-Host "`n=== ESP DEPLOYMENT STATUS SUMMARY ===" -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged — if ESP is still stuck, check the ESP timeout configuration in the Intune profile" "OK"
} else {
    $findings | Format-Table -AutoSize
}
Write-Host "`nEvidence written to: $OutputPath" -ForegroundColor Green
Write-Host "See Autopilot/Troubleshooting/ESP-Stuck-B.md for fix paths matching these flags." -ForegroundColor Cyan
