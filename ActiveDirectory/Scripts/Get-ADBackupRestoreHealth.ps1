<#
.SYNOPSIS
    Read-only risk assessment of AD DS backup/restore posture and USN rollback indicators.

.DESCRIPTION
    Collects and reports on:
      - System State backup history and age vs. tombstone lifetime (via wbadmin)
      - VSS writer health (specifically the NTDS writer)
      - Directory Service event log hits for USN rollback / database inconsistency
        (Event IDs 2095, 1113, 1115) and lingering objects (Event ID 1988)
      - AD Recycle Bin enablement status
      - Current replication options flags on this DC (flags DISABLE_OUTBOUND_REPL /
        DISABLE_INBOUND_REPL if already set, which usually means a prior USN rollback
        was auto-detected and never resolved)

    This script does NOT take backups, restore anything, reset the DSRM password,
    enable the Recycle Bin, or change any replication option. Read-only.
    Exports a consolidated CSV for escalation/reporting.

.PARAMETER BackupTarget
    Optional. Path or drive passed to `wbadmin get versions -backuptarget:<path>`.
    If omitted, checks the default local backup target.

.PARAMETER EventLookbackDays
    How many days back to scan the Directory Service event log for USN rollback /
    lingering object indicators. Default: 30.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\ADBackupRestoreHealth_<timestamp>.csv

.EXAMPLE
    .\Get-ADBackupRestoreHealth.ps1
    # Checks default local backup target, last 30 days of relevant events

.EXAMPLE
    .\Get-ADBackupRestoreHealth.ps1 -BackupTarget "\\backupserver\ADBackups" -EventLookbackDays 90
    # Checks a network backup target and widens the event log lookback window

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT), wbadmin.exe, vssadmin.exe
    Run as: Domain Admin or delegated AD read + local Administrator on the DC (wbadmin/vssadmin need local admin)
    Safe/Unsafe: READ-ONLY — does not take a backup, restore System State, reset the
                 DSRM password, enable AD Recycle Bin, or modify replication options
    Tested against: Windows Server 2016 / 2019 / 2022 domain controllers
    Limitation: wbadmin only reports backups it (or the same backup chain) is aware
                of — a third-party backup product's own catalog should be checked in
                addition to this script's output, not instead of it.
#>

[CmdletBinding()]
param(
    [string] $BackupTarget,
    [int]    $EventLookbackDays = 30,
    [string] $ExportPath = "$env:TEMP\ADBackupRestoreHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region --- Preflight ---

Write-Status "AD DS Backup/Restore Health Check" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: AD DS Tools." -Status "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

foreach ($tool in @("wbadmin.exe", "vssadmin.exe")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Status "$tool not found on PATH. This script must run on a Windows Server DC with backup tools present." -Status "ERROR"
        exit 1
    }
}

$thisDC = $env:COMPUTERNAME
Write-Status "Running on: $thisDC" -Status "INFO"
Write-Status "Prerequisites OK." -Status "OK"

#endregion

$results = @()

#region --- Backup History ---

Write-Status "`n=== Backup History (wbadmin) ===" -Status "HEADER"

try {
    $wbArgs = @("get", "versions")
    if ($BackupTarget) { $wbArgs += "-backuptarget:$BackupTarget" }
    $wbOut = & wbadmin @wbArgs 2>&1
    $wbText = $wbOut -join "`n"

    if ($wbText -match "no backups") {
        Write-Status "No System State backups found — no restore safety net exists for this DC." -Status "ERROR"
        $results += [PSCustomObject]@{ Category = "Backup"; Metric = "BackupExists"; Value = "None"; Status = "ERROR" }
    } else {
        # Parse "Backup time:" lines out of wbadmin's text output
        $backupTimes = $wbOut | Select-String -Pattern "Backup time:\s*(.+)" | ForEach-Object {
            try { [datetime]::Parse($_.Matches[0].Groups[1].Value) } catch { $null }
        } | Where-Object { $_ }

        if ($backupTimes) {
            $latest = ($backupTimes | Sort-Object -Descending)[0]
            $ageDays = [math]::Round(((Get-Date) - $latest).TotalDays, 1)
            Write-Status "Most recent backup: $latest ($ageDays days old)" -Status "OK"
            $results += [PSCustomObject]@{ Category = "Backup"; Metric = "MostRecentBackup"; Value = $latest; Status = "INFO" }
            $results += [PSCustomObject]@{ Category = "Backup"; Metric = "BackupAgeDays"; Value = $ageDays; Status = "INFO" }
        } else {
            Write-Status "Could not parse backup timestamps from wbadmin output — review raw output manually." -Status "WARN"
            $results += [PSCustomObject]@{ Category = "Backup"; Metric = "BackupParse"; Value = "Unparseable"; Status = "WARN" }
        }
    }
} catch {
    Write-Status "wbadmin query failed: $_" -Status "WARN"
    $results += [PSCustomObject]@{ Category = "Backup"; Metric = "BackupQuery"; Value = "Error"; Status = "WARN" }
}

#endregion

#region --- Tombstone Lifetime Comparison ---

Write-Status "`n=== Tombstone Lifetime ===" -Status "HEADER"

try {
    $domainDN = (Get-ADDomain).DistinguishedName
    $tsl = Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN" `
        -Properties tombstoneLifetime | Select-Object -ExpandProperty tombstoneLifetime
    if (-not $tsl) { $tsl = 180 }  # documented default if the attribute is unset
    Write-Status "Tombstone lifetime: $tsl days" -Status "INFO"
    $results += [PSCustomObject]@{ Category = "Backup"; Metric = "TombstoneLifetimeDays"; Value = $tsl; Status = "INFO" }

    if ($backupTimes -and $latest) {
        $ageDays = [math]::Round(((Get-Date) - $latest).TotalDays, 1)
        if ($ageDays -ge $tsl) {
            Write-Status "Most recent backup ($ageDays days old) EXCEEDS tombstone lifetime ($tsl days) — this backup is NOT safely restorable." -Status "ERROR"
            $results += [PSCustomObject]@{ Category = "Backup"; Metric = "BackupUsability"; Value = "Stale-Unusable"; Status = "ERROR" }
        } elseif ($ageDays -ge ($tsl * 0.75)) {
            Write-Status "Most recent backup is past 75% of tombstone lifetime — schedule a fresher backup soon." -Status "WARN"
            $results += [PSCustomObject]@{ Category = "Backup"; Metric = "BackupUsability"; Value = "Aging"; Status = "WARN" }
        } else {
            Write-Status "Most recent backup is well within tombstone lifetime." -Status "OK"
            $results += [PSCustomObject]@{ Category = "Backup"; Metric = "BackupUsability"; Value = "Valid"; Status = "OK" }
        }
    }
} catch {
    Write-Status "Could not read tombstone lifetime: $_" -Status "WARN"
    $results += [PSCustomObject]@{ Category = "Backup"; Metric = "TombstoneLifetime"; Value = "Error"; Status = "WARN" }
}

#endregion

#region --- VSS Writer Health ---

Write-Status "`n=== VSS Writer Health (NTDS) ===" -Status "HEADER"

try {
    $vssOut = & vssadmin list writers 2>&1
    $vssText = $vssOut -join "`n"
    # Find the NTDS writer block and check its state line
    $ntdsBlockMatch = [regex]::Match($vssText, "Writer name: 'NTDS'.*?(?=Writer name:|$)", "Singleline")
    if ($ntdsBlockMatch.Success) {
        $stateMatch = [regex]::Match($ntdsBlockMatch.Value, "State:\s*\[(\d+)\]\s*(.+)")
        if ($stateMatch.Success) {
            $stateText = $stateMatch.Groups[2].Value.Trim()
            if ($stateText -match "Stable") {
                Write-Status "NTDS VSS writer state: $stateText" -Status "OK"
                $results += [PSCustomObject]@{ Category = "VSS"; Metric = "NTDSWriterState"; Value = $stateText; Status = "OK" }
            } else {
                Write-Status "NTDS VSS writer state: $stateText — backups may be failing or inconsistent." -Status "ERROR"
                $results += [PSCustomObject]@{ Category = "VSS"; Metric = "NTDSWriterState"; Value = $stateText; Status = "ERROR" }
            }
        } else {
            Write-Status "Found NTDS writer block but could not parse state." -Status "WARN"
        }
    } else {
        Write-Status "NTDS VSS writer not found in vssadmin output — confirm this is a Domain Controller." -Status "WARN"
        $results += [PSCustomObject]@{ Category = "VSS"; Metric = "NTDSWriterFound"; Value = "No"; Status = "WARN" }
    }
} catch {
    Write-Status "vssadmin query failed: $_" -Status "WARN"
    $results += [PSCustomObject]@{ Category = "VSS"; Metric = "VSSQuery"; Value = "Error"; Status = "WARN" }
}

#endregion

#region --- USN Rollback / Lingering Object Event Scan ---

Write-Status "`n=== Directory Service Event Log Scan (last $EventLookbackDays days) ===" -Status "HEADER"

try {
    $since = (Get-Date).AddDays(-$EventLookbackDays)
    $events = Get-WinEvent -FilterHashtable @{ LogName = "Directory Service"; StartTime = $since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -in 2095, 1113, 1115, 1988 }

    if (-not $events -or $events.Count -eq 0) {
        Write-Status "No USN rollback, database inconsistency, or lingering object events found." -Status "OK"
        $results += [PSCustomObject]@{ Category = "Events"; Metric = "USNRollbackOrLingering"; Value = "None"; Status = "OK" }
    } else {
        $rollback = $events | Where-Object { $_.Id -in 2095, 1113, 1115 }
        $lingering = $events | Where-Object { $_.Id -eq 1988 }

        if ($rollback) {
            Write-Status "FOUND $($rollback.Count) USN rollback / DB inconsistency event(s) (2095/1113/1115) — treat as urgent, see AD-BackupRestore-B.md Fix 1." -Status "ERROR"
            $results += [PSCustomObject]@{ Category = "Events"; Metric = "USNRollbackEvents"; Value = $rollback.Count; Status = "ERROR" }
        }
        if ($lingering) {
            Write-Status "FOUND $($lingering.Count) lingering object event(s) (1988) — this is a replication issue, see AD-Replication-B.md, not this runbook." -Status "WARN"
            $results += [PSCustomObject]@{ Category = "Events"; Metric = "LingeringObjectEvents"; Value = $lingering.Count; Status = "WARN" }
        }
    }
} catch {
    Write-Status "Event log scan failed: $_" -Status "WARN"
    $results += [PSCustomObject]@{ Category = "Events"; Metric = "EventScan"; Value = "Error"; Status = "WARN" }
}

#endregion

#region --- Replication Isolation Flags ---

Write-Status "`n=== Replication Options Flags (this DC) ===" -Status "HEADER"

try {
    $repOptions = repadmin /options $thisDC 2>&1
    $repText = $repOptions -join " "
    if ($repText -match "DISABLE_OUTBOUND_REPL|DISABLE_INBOUND_REPL") {
        Write-Status "This DC currently has replication DISABLED (outbound and/or inbound) — usually set automatically after a USN rollback detection and left in place pending rebuild." -Status "ERROR"
        $results += [PSCustomObject]@{ Category = "Replication"; Metric = "ReplicationDisabledFlags"; Value = "Set"; Status = "ERROR" }
    } else {
        Write-Status "No replication-disabling flags set on this DC." -Status "OK"
        $results += [PSCustomObject]@{ Category = "Replication"; Metric = "ReplicationDisabledFlags"; Value = "Clear"; Status = "OK" }
    }
} catch {
    Write-Status "Could not query repadmin /options: $_" -Status "WARN"
    $results += [PSCustomObject]@{ Category = "Replication"; Metric = "ReplicationOptionsQuery"; Value = "Error"; Status = "WARN" }
}

#endregion

#region --- AD Recycle Bin Status ---

Write-Status "`n=== AD Recycle Bin ===" -Status "HEADER"

try {
    $recycleBin = Get-ADOptionalFeature -Filter 'Name -eq "Recycle Bin Feature"' | Select-Object -ExpandProperty EnabledScopes
    if ($recycleBin -and $recycleBin.Count -gt 0) {
        Write-Status "AD Recycle Bin is ENABLED." -Status "OK"
        $results += [PSCustomObject]@{ Category = "RecycleBin"; Metric = "Enabled"; Value = "Yes"; Status = "OK" }
    } else {
        Write-Status "AD Recycle Bin is NOT enabled — deleted-object recovery will require DSRM/authoritative restore instead of Restore-ADObject." -Status "WARN"
        $results += [PSCustomObject]@{ Category = "RecycleBin"; Metric = "Enabled"; Value = "No"; Status = "WARN" }
    }
} catch {
    Write-Status "Could not query AD Recycle Bin status: $_" -Status "WARN"
    $results += [PSCustomObject]@{ Category = "RecycleBin"; Metric = "Query"; Value = "Error"; Status = "WARN" }
}

#endregion

#region --- Export & Summary ---

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
Write-Host "  Checks run     : $($results.Count)"
Write-Host "  Errors         : $errorCount"
Write-Host "  Warnings       : $warnCount"
Write-Host "  Report saved to: $ExportPath"

if ($errorCount -gt 0) {
    Write-Status "One or more backup/restore posture issues detected — review the CSV and escalate if needed." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Minor issues or hardening gaps detected — review the CSV." -Status "WARN"
} else {
    Write-Status "Backup/restore posture looks healthy." -Status "OK"
}

#endregion
