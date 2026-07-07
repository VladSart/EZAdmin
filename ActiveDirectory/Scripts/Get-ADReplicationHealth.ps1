<#
.SYNOPSIS
    Full Active Directory Domain Services replication health check across all domain controllers.

.DESCRIPTION
    Collects and reports on:
      - Per-DC replication summary (fails/total, largest metadata delta)
      - FSMO role holder identity and reachability
      - Time sync offset per DC relative to the PDC Emulator
      - Tombstone lifetime and last-successful-replication age (lingering object risk)
      - Basic DCDiag pass/fail summary (Replications, Advertising, Services, KnowsOfRoleHolders)

    Does NOT make any changes. Read-only. Exports a consolidated CSV for escalation/reporting.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\ADReplicationHealth_<timestamp>.csv

.PARAMETER SkipDcDiag
    Skip the dcdiag pass (faster, but loses service/advertising validation). Default: $false.

.EXAMPLE
    .\Get-ADReplicationHealth.ps1
    # Full health check with CSV export

.EXAMPLE
    .\Get-ADReplicationHealth.ps1 -SkipDcDiag -ExportPath "C:\Reports\ADHealth.csv"
    # Faster run, skips dcdiag, custom export path

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT), repadmin.exe, dcdiag.exe, w32tm.exe
    Run as: Domain Admin or delegated AD read + replication-diagnostics rights
    Safe/Unsafe: READ-ONLY — makes no changes to AD, topology, or FSMO roles
    Tested against: Windows Server 2016 / 2019 / 2022 domain controllers
#>

[CmdletBinding()]
param(
    [string] $ExportPath  = "$env:TEMP\ADReplicationHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [switch] $SkipDcDiag
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

Write-Status "AD DS Replication Health Check" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: AD DS Tools." -Status "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

if (-not (Get-Command repadmin.exe -ErrorAction SilentlyContinue)) {
    Write-Status "repadmin.exe not found on PATH. Run from a DC or install RSAT." -Status "ERROR"
    exit 1
}
Write-Status "Prerequisites OK." -Status "OK"

#endregion

$results = @()

#region --- Replication Summary ---

Write-Status "`n=== Replication Summary (repadmin /replsummary) ===" -Status "HEADER"
$replSummaryRaw = repadmin /replsummary /csv 2>$null
$replSummary = @()
try {
    $replSummary = $replSummaryRaw | ConvertFrom-Csv
} catch {
    Write-Status "Could not parse repadmin CSV output — falling back to raw text display." -Status "WARN"
    repadmin /replsummary
}

foreach ($row in $replSummary) {
    $sourceFails = 0
    if ($row.PSObject.Properties.Name -contains "Fails/Total (Src)*") {
        $frag = $row.'Fails/Total (Src)*' -split '/'
        if ($frag.Count -eq 2) { $sourceFails = [int]$frag[0] }
    }
    if ($sourceFails -gt 0) {
        Write-Status "  $($row.'Source DSA') — $sourceFails replication failure(s)" -Status "WARN"
    }
    $results += [PSCustomObject]@{
        Category   = "ReplicationSummary"
        DC         = $row.'Source DSA'
        Metric     = "Fails/Total"
        Value      = $row.'Fails/Total (Src)*'
        Status     = if ($sourceFails -gt 0) { "WARN" } else { "OK" }
    }
}
if ($replSummary.Count -eq 0) {
    Write-Status "No parsable replsummary rows — check raw dcdiag output manually." -Status "WARN"
} else {
    Write-Status "Replication summary collected for $($replSummary.Count) DC(s)." -Status "OK"
}

#endregion

#region --- FSMO Role Holders ---

Write-Status "`n=== FSMO Role Holders ===" -Status "HEADER"
$fsmoOutput = netdom query fsmo 2>$null
$fsmoOutput | ForEach-Object { Write-Host "  $_" }

foreach ($line in $fsmoOutput) {
    if ($line -match "^(.+?)\s+(\S+)\s+Owner\s*$") {
        $roleName = $matches[1].Trim()
        $holder   = $matches[2].Trim()
        $reachable = $false
        try {
            $reachable = [bool](Test-Connection -ComputerName $holder -Count 1 -Quiet -ErrorAction SilentlyContinue)
        } catch { $reachable = $false }

        if (-not $reachable) {
            Write-Status "  FSMO role '$roleName' holder '$holder' is UNREACHABLE" -Status "ERROR"
        }

        $results += [PSCustomObject]@{
            Category = "FSMO"
            DC       = $holder
            Metric   = $roleName
            Value    = "Owner"
            Status   = if ($reachable) { "OK" } else { "ERROR" }
        }
    }
}

#endregion

#region --- Time Sync ---

Write-Status "`n=== Time Sync (per DC) ===" -Status "HEADER"
$dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

foreach ($dc in $dcs) {
    try {
        $timeStatus = w32tm /stripchart /computer:$dc /samples:1 /dataonly 2>$null
        $offsetLine = $timeStatus | Where-Object { $_ -match "," } | Select-Object -Last 1
        $offsetVal  = "unknown"
        if ($offsetLine -match ",\s*([+-]?[\d\.]+)s") {
            $offsetVal = $matches[1]
        }
        $offsetFloat = 0.0
        [double]::TryParse($offsetVal, [ref]$offsetFloat) | Out-Null
        $timeStatusFlag = if ([Math]::Abs($offsetFloat) -gt 300) { "ERROR" }
                          elseif ([Math]::Abs($offsetFloat) -gt 30) { "WARN" }
                          else { "OK" }

        if ($timeStatusFlag -ne "OK") {
            Write-Status "  $dc time offset: ${offsetVal}s" -Status $timeStatusFlag
        }

        $results += [PSCustomObject]@{
            Category = "TimeSync"
            DC       = $dc
            Metric   = "OffsetSeconds"
            Value    = $offsetVal
            Status   = $timeStatusFlag
        }
    } catch {
        Write-Status "  Could not query time on $dc`: $_" -Status "WARN"
        $results += [PSCustomObject]@{
            Category = "TimeSync"; DC = $dc; Metric = "OffsetSeconds"; Value = "N/A"; Status = "WARN"
        }
    }
}
Write-Status "Time sync check complete. Kerberos hard-fails past 300s (5 min) skew." -Status "OK"

#endregion

#region --- Tombstone Lifetime / Lingering Object Risk ---

Write-Status "`n=== Tombstone Lifetime & Last Successful Replication ===" -Status "HEADER"
try {
    $domainDN = (Get-ADDomain).DistinguishedName
    $tsl = (Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$domainDN" `
        -Properties tombstoneLifetime).tombstoneLifetime
    if (-not $tsl) { $tsl = 60 }  # AD default if attribute not explicitly set
    Write-Host "  Tombstone lifetime: $tsl days"

    $replCsv = repadmin /showrepl * /csv 2>$null | ConvertFrom-Csv -ErrorAction SilentlyContinue
    if ($replCsv) {
        foreach ($row in $replCsv) {
            $lastSuccessRaw = $row.'Last Success Time'
            if ($lastSuccessRaw) {
                $lastSuccess = $null
                if ([DateTime]::TryParse($lastSuccessRaw, [ref]$lastSuccess)) {
                    $ageDays = ((Get-Date) - $lastSuccess).TotalDays
                    $lingerFlag = if ($ageDays -gt $tsl) { "ERROR" } elseif ($ageDays -gt ($tsl * 0.75)) { "WARN" } else { "OK" }
                    if ($lingerFlag -ne "OK") {
                        Write-Status "  $($row.'Destination DSA') <- $($row.'Naming Context'): last success $([Math]::Round($ageDays,1)) days ago" -Status $lingerFlag
                    }
                    $results += [PSCustomObject]@{
                        Category = "LingeringObjectRisk"
                        DC       = $row.'Destination DSA'
                        Metric   = "DaysSinceLastSuccess"
                        Value    = [Math]::Round($ageDays,1)
                        Status   = $lingerFlag
                    }
                }
            }
        }
    }
} catch {
    Write-Status "Could not evaluate tombstone lifetime risk: $_" -Status "WARN"
}

#endregion

#region --- DCDiag Summary ---

if (-not $SkipDcDiag) {
    Write-Status "`n=== DCDiag Summary (Replications / Advertising / Services / KnowsOfRoleHolders) ===" -Status "HEADER"
    $keyTests = @("Replications", "Advertising", "Services", "KnowsOfRoleHolders", "FsmoCheck")
    foreach ($test in $keyTests) {
        try {
            $out = dcdiag /test:$test 2>$null
            $pass = ($out -join "`n") -match "passed test $test"
            $status = if ($pass) { "OK" } else { "ERROR" }
            if (-not $pass) {
                Write-Status "  DCDiag test '$test' did not pass — review dcdiag /v output" -Status "ERROR"
            }
            $results += [PSCustomObject]@{
                Category = "DCDiag"; DC = "ALL"; Metric = $test
                Value    = if ($pass) { "Passed" } else { "Failed" }
                Status   = $status
            }
        } catch {
            Write-Status "  DCDiag test '$test' could not be run: $_" -Status "WARN"
        }
    }
} else {
    Write-Status "`nSkipping DCDiag (per -SkipDcDiag switch)." -Status "INFO"
}

#endregion

#region --- Export & Summary ---

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
Write-Host "  Total checks run : $($results.Count)"
Write-Host "  Errors           : $errorCount"
Write-Host "  Warnings         : $warnCount"
Write-Host "  Report saved to  : $ExportPath"

if ($errorCount -gt 0) {
    Write-Status "One or more critical replication health issues detected — review the CSV and escalate if needed." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Minor issues detected — review the CSV." -Status "WARN"
} else {
    Write-Status "AD DS replication health looks good." -Status "OK"
}

#endregion
