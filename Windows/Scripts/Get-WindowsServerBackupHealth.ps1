<#
.SYNOPSIS
    Read-only health check for Windows Server Backup (wbadmin) on the local server.

.DESCRIPTION
    Checks the Windows-Server-Backup feature, the configured policy (BMR / System State /
    volumes / schedule / VSS option), the backup target (type, free space, single-version
    network share warning), the last job result and age of the last successful backup,
    the backup scheduled task, VSS writers / providers / shadow storage, and recent errors
    in the Microsoft-Windows-Backup operational log.

    Covers: Windows Server 2016 / 2019 / 2022 / 2025 with the in-box WSB feature.
    Does NOT cover: Azure Backup MARS agent, third-party backup products, restore testing.
    Makes no changes.

.PARAMETER MaxAgeHours
    Maximum acceptable age (hours) of the last successful backup before it is flagged. Default 26.

.PARAMETER MinTargetFreePercent
    Flag the target if free space is below this percentage. Default 15.

.PARAMETER OutputPath
    Folder for the CSV report. Default C:\Temp.

.EXAMPLE
    .\Get-WindowsServerBackupHealth.ps1

.EXAMPLE
    .\Get-WindowsServerBackupHealth.ps1 -MaxAgeHours 50 -OutputPath D:\Reports

.NOTES
    Requires: elevated PowerShell 5.1+, Windows Server. WindowsServerBackup module for policy checks.
    Safe: read-only (vssadmin list, Get-WB*, Get-WinEvent).
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [int]$MaxAgeHours = 26,
    [int]$MinTargetFreePercent = 15,
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; Check = $Check; Status = $Status; Detail = $Detail
        Timestamp = (Get-Date).ToString('s')
    })
    Write-Status -Message "$Check - $Detail" -Status $Status
}

# ---------------- Preflight ----------------
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$featureOk = $false
try {
    $feature = Get-WindowsFeature -Name Windows-Server-Backup
    if ($feature.InstallState -eq 'Installed') {
        $featureOk = $true
        Add-Result 'Feature' 'OK' 'Windows-Server-Backup installed'
    } else {
        Add-Result 'Feature' 'ERROR' "Windows-Server-Backup state: $($feature.InstallState)"
    }
} catch {
    Add-Result 'Feature' 'WARN' "Get-WindowsFeature unavailable (client OS?): $($_.Exception.Message)"
}

if ($featureOk) {
    try { Import-Module WindowsServerBackup -ErrorAction Stop } catch {
        Add-Result 'Module' 'ERROR' "WindowsServerBackup module failed to load: $($_.Exception.Message)"
        $featureOk = $false
    }
}

# ---------------- Detect: policy ----------------
$policy = $null
if ($featureOk) {
    try { $policy = Get-WBPolicy -ErrorAction Stop } catch { $policy = $null }
    if (-not $policy) {
        Add-Result 'Policy' 'ERROR' 'No scheduled backup policy configured'
    } else {
        $sched = ($policy.Schedule | ForEach-Object { $_.ToString('HH:mm') }) -join ', '
        Add-Result 'Policy.Schedule' ($(if ($sched) {'OK'} else {'WARN'})) "Schedule: $sched"
        Add-Result 'Policy.BMR' ($(if ($policy.BMR) {'OK'} else {'WARN'})) "Bare metal recovery included: $($policy.BMR)"
        Add-Result 'Policy.SystemState' ($(if ($policy.SystemState) {'OK'} else {'WARN'})) "System state included: $($policy.SystemState)"
        try {
            $vols = @(Get-WBVolume -Policy $policy)
            Add-Result 'Policy.Volumes' 'INFO' ("Volumes: " + (($vols | ForEach-Object { $_.MountPath }) -join ', '))
        } catch { Add-Result 'Policy.Volumes' 'WARN' "Could not read volumes: $($_.Exception.Message)" }
        try {
            $vssOpt = Get-WBVssBackupOption -Policy $policy
            Add-Result 'Policy.VssOption' 'INFO' "VSS backup option: $vssOpt (Full truncates app logs, Copy does not)"
        } catch { }

        # ---------------- Detect: targets ----------------
        try {
            $targets = @(Get-WBBackupTarget -Policy $policy)
            if ($targets.Count -eq 0) { Add-Result 'Target' 'ERROR' 'Policy has no backup target' }
            foreach ($t in $targets) {
                $label = if ($t.Label) { $t.Label } else { $t.TargetPath }
                if ("$($t.TargetType)" -match 'Network') {
                    Add-Result "Target[$label]" 'WARN' "Network share target $($t.TargetPath) - holds ONE version only"
                }
                if ($t.TotalSpace -gt 0) {
                    $pct = [math]::Round(($t.FreeSpace / $t.TotalSpace) * 100, 1)
                    $st  = if ($pct -lt $MinTargetFreePercent) {'WARN'} else {'OK'}
                    Add-Result "Target[$label]" $st ("Type {0}; free {1:N1} GB of {2:N1} GB ({3}%)" -f $t.TargetType, ($t.FreeSpace/1GB), ($t.TotalSpace/1GB), $pct)
                } else {
                    Add-Result "Target[$label]" 'INFO' "Type $($t.TargetType); size not reported (offline/rotated or network)"
                }
            }
        } catch { Add-Result 'Target' 'WARN' "Could not read targets: $($_.Exception.Message)" }
    }

    # ---------------- Detect: summary / last job ----------------
    try {
        $sum = Get-WBSummary
        $hr  = '0x{0:X8}' -f [int64]$sum.LastBackupResultHR
        if ($sum.LastSuccessfulBackupTime -and $sum.LastSuccessfulBackupTime -gt [datetime]'2000-01-01') {
            $age = [math]::Round(((Get-Date) - $sum.LastSuccessfulBackupTime).TotalHours, 1)
            $st  = if ($age -gt $MaxAgeHours) {'ERROR'} else {'OK'}
            Add-Result 'LastSuccess' $st "Last successful backup $($sum.LastSuccessfulBackupTime) ($age h ago; threshold $MaxAgeHours h)"
        } else {
            Add-Result 'LastSuccess' 'ERROR' 'No successful backup recorded'
        }
        $st = if ($sum.LastBackupResultHR -eq 0) {'OK'} else {'ERROR'}
        Add-Result 'LastResult' $st "Last backup $($sum.LastBackupTime) result $hr"
        Add-Result 'Versions' 'INFO' "Versions in catalog: $($sum.NumberOfVersions); next backup: $($sum.NextBackupTime)"
    } catch { Add-Result 'Summary' 'WARN' "Get-WBSummary failed: $($_.Exception.Message)" }
}

# ---------------- Detect: scheduled task ----------------
try {
    $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Backup\' -TaskName 'Microsoft-Windows-WindowsBackup' -ErrorAction Stop
    $info = $task | Get-ScheduledTaskInfo
    $st = if ($task.State -eq 'Disabled') {'ERROR'} else {'OK'}
    Add-Result 'ScheduledTask' $st ("State {0}; last run {1}; last result 0x{2:X}; next {3}" -f $task.State, $info.LastRunTime, $info.LastTaskResult, $info.NextRunTime)
} catch {
    $st = if ($policy) {'WARN'} else {'INFO'}
    Add-Result 'ScheduledTask' $st 'Backup scheduled task not found'
}

# ---------------- Detect: VSS ----------------
try {
    $writerText = (vssadmin list writers) -join "`n"
    $blocks = $writerText -split 'Writer name:' | Select-Object -Skip 1
    $bad = 0
    foreach ($b in $blocks) {
        $name  = ($b -split "`n")[0].Trim().Trim("'")
        $state = if ($b -match 'State:\s*\[\d+\]\s*([^\r\n]+)') { $Matches[1].Trim() } else { '?' }
        $err   = if ($b -match 'Last error:\s*([^\r\n]+)') { $Matches[1].Trim() } else { '?' }
        if ($state -ne 'Stable' -or $err -ne 'No error') {
            $bad++
            Add-Result "VSSWriter[$name]" 'ERROR' "State $state; last error $err"
        }
    }
    if ($bad -eq 0) { Add-Result 'VSSWriters' 'OK' "$($blocks.Count) writers Stable / No error" }
} catch { Add-Result 'VSSWriters' 'WARN' "vssadmin list writers failed: $($_.Exception.Message)" }

try {
    $provText = (vssadmin list providers) -join "`n"
    $provNames = [regex]::Matches($provText, "Provider name:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    $nonMs = @($provNames | Where-Object { $_ -notmatch '^Microsoft ' })
    if ($nonMs.Count -gt 0) {
        Add-Result 'VSSProviders' 'WARN' ("Non-Microsoft VSS providers present: " + ($nonMs -join '; '))
    } else {
        Add-Result 'VSSProviders' 'OK' ("Providers: " + ($provNames -join '; '))
    }
} catch { Add-Result 'VSSProviders' 'WARN' "vssadmin list providers failed: $($_.Exception.Message)" }

try {
    $ssText = (vssadmin list shadowstorage) -join "`n"
    $count = ([regex]::Matches($ssText, 'For volume:')).Count
    $st = if ($count -eq 0) {'WARN'} else {'INFO'}
    Add-Result 'ShadowStorage' $st "Shadow storage associations: $count"
} catch { Add-Result 'ShadowStorage' 'WARN' "vssadmin list shadowstorage failed: $($_.Exception.Message)" }

# ---------------- Detect: event log ----------------
try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Backup'; Level = 1,2; StartTime = (Get-Date).AddDays(-7) } -ErrorAction Stop)
    $top = $ev | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 |
        ForEach-Object { "ID $($_.Name) x$($_.Count)" }
    Add-Result 'BackupLog7d' 'WARN' ("$($ev.Count) errors in 7 days: " + ($top -join ', '))
    $latest = $ev | Sort-Object TimeCreated -Descending | Select-Object -First 1
    $msg = ($latest.Message -replace '\s+', ' ')
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
    Add-Result 'BackupLogLatest' 'WARN' "$($latest.TimeCreated) ID $($latest.Id): $msg"
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        Add-Result 'BackupLog7d' 'OK' 'No backup errors in the last 7 days'
    } else {
        Add-Result 'BackupLog7d' 'INFO' "Backup log not readable: $($_.Exception.Message)"
    }
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath ("WSBHealth_{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$errs  = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. $errs error(s), $warns warning(s). Report: $csv" ($(if ($errs) {'ERROR'} elseif ($warns) {'WARN'} else {'OK'}))
