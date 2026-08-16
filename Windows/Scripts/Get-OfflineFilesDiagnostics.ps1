<#
.SYNOPSIS
    Audits Folder Redirection and Offline Files (CSC) health for the current user/machine —
    redirection targets vs. GPO intent, Offline Files service/policy state, cache size headroom,
    slow-link/Always-Offline configuration, and recent sync failure events.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/FolderRedirection-B.md and FolderRedirection-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - Live redirection target paths (User Shell Folders) — flags any still pointing locally
    - Offline Files (CscService) service state and policy-level enablement
    - Local CSC cache size vs. configured (or default 25%) limit
    - Slow-link mode / Always Offline configuration, with an explicit Latency=1 flag
    - AppData (Roaming) redirection detection — flags the documented anti-pattern if present
    - Recent Microsoft-Windows-OfflineFiles/Operational error/warning events
    - Reachability of the redirected folders' target UNC paths

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's FolderRedirection-B.md Fix 1-6 / -A.md Playbooks 1-4)
    - Sync Center conflict enumeration — no reliable headless equivalent exists; conflicts must
      be reviewed via the Sync Center GUI (`control /name Microsoft.SyncCenter`)
    - BranchCache's own health — see Get-BranchCacheHealth.ps1 for the shared CscService
      dependency from that feature's side

.PARAMETER ExportPath
    Path for CSV export. Default: .\OfflineFilesDiagnostics-<timestamp>.csv

.EXAMPLE
    .\Get-OfflineFilesDiagnostics.ps1
    Audits Folder Redirection and Offline Files state for the CURRENT user running the script.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Run in the AFFECTED USER's own session/profile context — HKCU and per-user CSC
            pinning state cannot be read cross-user without additional profile-loading steps.
    Safe: Fully read-only. No redirection changes, no service state changes, no cache clearing.
    Tested on: Windows 10 21H2+, Windows 11, Windows Server 2016+ (RDS/session-host scenarios)
#>

[CmdletBinding()]
param(
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
Write-Status "Get-OfflineFilesDiagnostics — $(Get-Date -Format 'yyyy-MM-dd HH:mm') — user: $env:USERNAME"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\OfflineFilesDiagnostics-$timestamp.csv"
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

#region ─── 1. Redirection targets ──────────────────────────────────────────────
try {
    $shellFoldersPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $shellFolders = Get-ItemProperty -Path $shellFoldersPath -ErrorAction Stop

    $foldersToCheck = @('Desktop', 'Personal', '{374DE290-123F-4565-9164-39C4925E467B}', 'My Pictures')
    $redirectedCount = 0
    $localCount = 0

    foreach ($prop in $shellFolders.PSObject.Properties) {
        if ($prop.Value -match '^\\\\') {
            $redirectedCount++
        } elseif ($prop.Name -in $foldersToCheck -and $prop.Value -match '^[A-Za-z]:\\') {
            $localCount++
        }
    }
    Add-Result "RedirectionTargets" "INFO" "$redirectedCount folder(s) show a UNC (redirected) path; review export for details on which specific folders"
    $shellFolders.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
        Select-Object Name, Value | Export-Csv -Path "$($ExportPath -replace '\.csv$','')-ShellFolders.csv" -NoTypeInformation
} catch {
    Add-Result "RedirectionTargets" "WARN" "Could not read User Shell Folders registry values: $_"
}
#endregion

#region ─── 2. AppData (Roaming) redirection anti-pattern check ────────────────
try {
    $appDataRoaming = (Get-ItemProperty -Path $shellFoldersPath -Name "AppData" -ErrorAction SilentlyContinue).AppData
    if ($appDataRoaming -match '^\\\\') {
        Add-Result "AppDataRoamingRedirection" "WARN" "AppData\Roaming IS redirected to $appDataRoaming — documented anti-pattern, high conflict/corruption risk for apps with continuously-open files"
    } else {
        Add-Result "AppDataRoamingRedirection" "OK" "AppData\Roaming is NOT redirected (local) — expected/recommended state"
    }
} catch {
    Add-Result "AppDataRoamingRedirection" "INFO" "Could not determine AppData\Roaming redirection state: $_"
}
#endregion

#region ─── 3. Offline Files service state ──────────────────────────────────────
try {
    $csc = Get-Service -Name CscService -ErrorAction Stop
    if ($csc.Status -eq 'Running') {
        Add-Result "CscServiceState" "OK" "Running (StartType: $($csc.StartType))"
    } else {
        Add-Result "CscServiceState" "ERROR" "Status: $($csc.Status) — redirected folders will fail or appear empty the moment the network path is unreachable"
    }
} catch {
    Add-Result "CscServiceState" "ERROR" "Could not query CscService: $_"
}
#endregion

#region ─── 4. Offline Files policy-level enablement ────────────────────────────
try {
    $netCachePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache"
    if (Test-Path $netCachePolicy) {
        $enabled = (Get-ItemProperty -Path $netCachePolicy -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
        if ($null -ne $enabled -and $enabled -eq 0) {
            Add-Result "OfflineFilesPolicy" "ERROR" "Offline Files explicitly DISABLED via policy (Enabled=0) — overrides service state entirely"
        } else {
            Add-Result "OfflineFilesPolicy" "OK" "No explicit policy disablement found (default-on, or explicitly enabled)"
        }
    } else {
        Add-Result "OfflineFilesPolicy" "OK" "No GPO NetCache policy key present — default (enabled) behavior applies"
    }
} catch {
    Add-Result "OfflineFilesPolicy" "INFO" "Could not check Offline Files policy state: $_"
}
#endregion

#region ─── 5. Slow-link mode / Always Offline detection ───────────────────────
try {
    $netCachePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache"
    $slowLink = Get-ItemProperty -Path $netCachePolicy -Name "SlowLinkEntries" -ErrorAction SilentlyContinue
    if ($slowLink) {
        $slowLinkText = $slowLink.SlowLinkEntries -join '; '
        if ($slowLinkText -match 'Latency=1(?!\d)') {
            Add-Result "SlowLinkMode" "INFO" "Always Offline mode detected (Latency=1) — client deliberately never transitions to Online mode for the configured path(s). Entries: $slowLinkText"
        } else {
            Add-Result "SlowLinkMode" "INFO" "Adaptive slow-link mode configured (non-1 latency threshold). Entries: $slowLinkText"
        }
    } else {
        Add-Result "SlowLinkMode" "INFO" "No slow-link mode configured — client uses default synchronous online/offline transition (full fetch on every logon over any link speed)"
    }
} catch {
    Add-Result "SlowLinkMode" "INFO" "Could not check slow-link mode configuration: $_"
}
#endregion

#region ─── 6. CSC cache size headroom ──────────────────────────────────────────
try {
    if (Test-Path "C:\Windows\CSC") {
        $cacheStats = Get-ChildItem "C:\Windows\CSC" -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
        $cacheMB = [math]::Round(($cacheStats.Sum / 1MB), 2)

        $driveInfo = Get-PSDrive -Name C -ErrorAction SilentlyContinue
        if ($driveInfo) {
            $driveTotalMB = [math]::Round((($driveInfo.Used + $driveInfo.Free) / 1MB), 2)
            $defaultLimitMB = [math]::Round($driveTotalMB * 0.25, 2)
            $pctOfDefaultLimit = if ($defaultLimitMB -gt 0) { [math]::Round(($cacheMB / $defaultLimitMB) * 100, 1) } else { 0 }

            if ($pctOfDefaultLimit -ge 90) {
                Add-Result "CSCCacheSize" "WARN" "Cache ~$cacheMB MB, ~$pctOfDefaultLimit% of the DEFAULT 25%-of-drive limit ($defaultLimitMB MB) — approaching ceiling, check for a custom policy limit too"
            } else {
                Add-Result "CSCCacheSize" "OK" "Cache ~$cacheMB MB (~$pctOfDefaultLimit% of default 25%-of-drive limit, $defaultLimitMB MB)"
            }
        } else {
            Add-Result "CSCCacheSize" "INFO" "Cache size ~$cacheMB MB — could not determine drive capacity for limit comparison"
        }
    } else {
        Add-Result "CSCCacheSize" "INFO" "C:\Windows\CSC not found or not accessible — Offline Files cache may be empty/unused or on a non-default path"
    }
} catch {
    Add-Result "CSCCacheSize" "WARN" "Could not measure CSC cache size: $_"
}
#endregion

#region ─── 7. Recent Offline Files operational errors/warnings ────────────────
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-OfflineFiles/Operational" -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.LevelDisplayName -in @('Error', 'Warning') }
    if ($events) {
        Add-Result "RecentSyncEvents" "WARN" "$($events.Count) Error/Warning event(s) in the last 200 log entries — see exported CSV for detail"
        $events | Select-Object TimeCreated, Id, LevelDisplayName, Message |
            Export-Csv -Path "$($ExportPath -replace '\.csv$','')-Events.csv" -NoTypeInformation
    } else {
        Add-Result "RecentSyncEvents" "OK" "No Error/Warning events found in the last 200 Offline Files operational log entries"
    }
} catch {
    Add-Result "RecentSyncEvents" "INFO" "Could not read Microsoft-Windows-OfflineFiles/Operational log (may not exist on this OS/config): $_"
}
#endregion

#region ─── 8. Redirected folder target reachability ───────────────────────────
try {
    $shellFolders = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction Stop
    $uncTargets = $shellFolders.PSObject.Properties | Where-Object { $_.Value -match '^\\\\' }
    if ($uncTargets) {
        foreach ($target in $uncTargets) {
            $reachable = Test-Path $target.Value -ErrorAction SilentlyContinue
            $status = if ($reachable) { "OK" } else { "WARN" }
            $note = if ($reachable) { "reachable" } else { "NOT reachable right now — if CscService/Offline Files is healthy, this is expected offline behavior, not necessarily a fault" }
            Add-Result "PathReachable-$($target.Name)" $status "$($target.Value) — $note"
        }
    } else {
        Add-Result "PathReachable" "INFO" "No UNC-redirected folders found to test"
    }
} catch {
    Add-Result "PathReachable" "INFO" "Could not test redirected path reachability: $_"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Folder Redirection / Offline Files Diagnostics Summary ─────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run   : $($results.Count)"
Write-Host "  Errors       : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings     : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Folder Redirection / Offline Files configuration looks healthy for this user." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see FolderRedirection-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host "  NOTE: Sync Center conflict state is NOT captured here — review manually via 'control /name Microsoft.SyncCenter'" -ForegroundColor Cyan
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
