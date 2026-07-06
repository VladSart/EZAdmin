<#
.SYNOPSIS
    Collects Windows Event Log service health, log status, and corruption indicators for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/EventLog-B.md.
    Gathers, in one pass, everything the runbook's triage and diagnosis steps ask for:
    - EventLog service status and its dependency chain (WinMgmt, RpcEptMapper, DcomLaunch)
    - Log mode (Retain/Circular/AutoBackup), size, and record count for core logs
    - Event ID 6 (log corruption), 104/1102 (log cleared) in the last lookback window
    - OS disk free space (logs cannot grow / rotate without headroom)
    - Security log retention policy setting
    - A synthetic write-and-verify test to confirm the pipeline is actually working

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Clearing or archiving logs (that's EventLog-B.md Fix 2 / Fix 3)
    - Repairing ACLs on redirected log paths (that's Fix 4 — this script only detects the redirect)
    - SIEM/forwarder-side health (Sentinel, Splunk, etc.) — client-side only

.PARAMETER LogNames
    Array of log names to check status/mode for. Default: Application, System, Security.

.PARAMETER LookbackHours
    How far back to search for corruption (Event ID 6) and clear (104/1102) events. Default: 24.

.PARAMETER SkipWriteTest
    Skip the synthetic Write-EventLog test (useful if you don't want a test event landing in Application log).

.PARAMETER ExportPath
    Path for CSV export. Default: .\EventLogDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-EventLogDiagnostics.ps1
    Runs the full triage sweep against Application, System, and Security logs with a 24-hour lookback.

.EXAMPLE
    .\Get-EventLogDiagnostics.ps1 -LogNames Application,System -LookbackHours 72 -SkipWriteTest
    Checks only Application and System, widens the lookback to 3 days, and skips the synthetic write test.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator (required to read Security log and query service dependencies reliably)
    Safe: Read-only by default. The synthetic write test adds one Information-level event to the
          Application log (Source "EZAdminDiag", EventId 9999) unless -SkipWriteTest is used.
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2019/2022
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string[]]$LogNames = @('Application', 'System', 'Security'),

    [int]$LookbackHours = 24,

    [switch]$SkipWriteTest,

    [string]$ExportPath
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

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-EventLogDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\EventLogDiagnostics-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "$Check — $Detail" $Status
}
#endregion

#region ─── 1. EventLog service and dependency chain ───────────────────────────
try {
    $svc = Get-Service -Name EventLog -ErrorAction Stop
    if ($svc.Status -eq 'Running') {
        Add-Result "EventLogService" "OK" "Running (StartType: $($svc.StartType))"
    } else {
        Add-Result "EventLogService" "ERROR" "Status: $($svc.Status) — core logging is down"
    }
} catch {
    Add-Result "EventLogService" "ERROR" "Could not query EventLog service: $_"
}

foreach ($dep in @('WinMgmt', 'RpcEptMapper', 'DcomLaunch')) {
    try {
        $depSvc = Get-Service -Name $dep -ErrorAction Stop
        if ($depSvc.Status -eq 'Running') {
            Add-Result "Dependency-$dep" "OK" "Running"
        } else {
            Add-Result "Dependency-$dep" "ERROR" "Status: $($depSvc.Status) — EventLog depends on this"
        }
    } catch {
        Add-Result "Dependency-$dep" "WARN" "Could not query: $_"
    }
}
#endregion

#region ─── 2. Log mode, size, record count ────────────────────────────────────
foreach ($log in $LogNames) {
    try {
        $logInfo = Get-WinEvent -ListLog $log -ErrorAction Stop
        $pctFull = if ($logInfo.MaximumSizeInBytes -gt 0) {
            [math]::Round(($logInfo.FileSize / $logInfo.MaximumSizeInBytes) * 100, 1)
        } else { 0 }

        $detail = "Mode=$($logInfo.LogMode); Records=$($logInfo.RecordCount); ~$pctFull% of max size"

        if ($logInfo.LogMode -eq 'Retain' -and $pctFull -ge 90) {
            Add-Result "LogStatus-$log" "ERROR" "$detail — Retain mode + near-full = new events will be dropped"
        } elseif ($pctFull -ge 90) {
            Add-Result "LogStatus-$log" "WARN" "$detail — approaching capacity"
        } else {
            Add-Result "LogStatus-$log" "OK" $detail
        }
    } catch {
        Add-Result "LogStatus-$log" "WARN" "Could not read log info for '$log': $_"
    }
}
#endregion

#region ─── 3. Corruption / clear events in lookback window ────────────────────
try {
    $startTime = (Get-Date).AddHours(-$LookbackHours)
    $corruptionEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = 6
        StartTime = $startTime
    } -ErrorAction SilentlyContinue

    if ($corruptionEvents -and $corruptionEvents.Count -gt 0) {
        Add-Result "LogCorruption" "ERROR" "$($corruptionEvents.Count) Event ID 6 (corruption) in last $LookbackHours h"
    } else {
        Add-Result "LogCorruption" "OK" "No Event ID 6 (corruption) in last $LookbackHours h"
    }
} catch {
    Add-Result "LogCorruption" "OK" "No matching events / query returned none"
}

try {
    $startTime = (Get-Date).AddHours(-$LookbackHours)
    $clearEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = @(104, 1102)
        StartTime = $startTime
    } -ErrorAction SilentlyContinue

    if ($clearEvents -and $clearEvents.Count -gt 0) {
        Add-Result "LogCleared" "WARN" "$($clearEvents.Count) log-clear event(s) (104/1102) in last $LookbackHours h — investigate who/why"
    } else {
        Add-Result "LogCleared" "OK" "No log-clear events (104/1102) in last $LookbackHours h"
    }
} catch {
    Add-Result "LogCleared" "OK" "No matching events / query returned none"
}
#endregion

#region ─── 4. Disk free space on OS volume ─────────────────────────────────────
try {
    $osDrive = (Get-CimInstance Win32_OperatingSystem).SystemDrive.TrimEnd(':')
    $drive = Get-PSDrive -Name $osDrive -ErrorAction Stop
    $freeGB = [math]::Round($drive.Free / 1GB, 2)

    if ($freeGB -lt 0.5) {
        Add-Result "DiskFreeSpace" "ERROR" "$($osDrive): only $freeGB GB free — logs cannot rotate, new events may be dropped silently"
    } elseif ($freeGB -lt 1) {
        Add-Result "DiskFreeSpace" "WARN" "$($osDrive): $freeGB GB free — getting low"
    } else {
        Add-Result "DiskFreeSpace" "OK" "$($osDrive): $freeGB GB free"
    }
} catch {
    Add-Result "DiskFreeSpace" "WARN" "Could not determine disk free space: $_"
}
#endregion

#region ─── 5. Security log retention policy ────────────────────────────────────
try {
    $retention = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security" -ErrorAction Stop).Retention
    if ($retention -eq 0) {
        Add-Result "SecurityRetentionPolicy" "OK" "Retention=0 (overwrite as needed)"
    } elseif ($retention -eq 4294967295) {
        Add-Result "SecurityRetentionPolicy" "WARN" "Retention=-1 (never overwrite) — combined with a full log this drops new events"
    } else {
        Add-Result "SecurityRetentionPolicy" "WARN" "Retention=$retention (non-default, likely AutoBackup interval)"
    }
} catch {
    Add-Result "SecurityRetentionPolicy" "WARN" "Could not read retention registry value: $_"
}
#endregion

#region ─── 6. Synthetic write-and-verify test ─────────────────────────────────
if (-not $SkipWriteTest) {
    try {
        $testId = 9999
        Write-EventLog -LogName Application -Source "EZAdminDiag" -EventId $testId -EntryType Information -Message "EZAdmin diagnostics test event" -ErrorAction Stop

        Start-Sleep -Seconds 2
        $landed = Get-WinEvent -LogName Application -MaxEvents 20 -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -eq $testId -and $_.ProviderName -eq 'EZAdminDiag' }

        if ($landed) {
            Add-Result "WriteTest" "OK" "Synthetic event written and verified in Application log"
        } else {
            Add-Result "WriteTest" "WARN" "Write did not throw but event was not found on read-back"
        }
    } catch {
        Add-Result "WriteTest" "ERROR" "Write-EventLog failed: $_ — check service/permissions"
    }
} else {
    Add-Result "WriteTest" "INFO" "Skipped (-SkipWriteTest)"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Event Log Diagnostics Summary ─────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Event Log service and logs look healthy on this client." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see EventLog-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
