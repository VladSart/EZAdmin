<#
.SYNOPSIS
    Read-only readiness and health audit for Windows 11 point-in-time restore (PITR) on the local device.

.DESCRIPTION
    Checks everything that decides whether a point-in-time restore will actually work when it's needed:

      - OS build/UBR against the Recovery CSP minimums (24H2 26100.8737+, 25H2 26200.8737+) and edition
      - Management state (domain / Entra / MDM), which drives the OFF-by-default rule until 26H2
      - WinRE enabled (the restore UI only exists in WinRE)
      - Restore point (VSS shadow copy) inventory on the OS volume: count, oldest, newest, span
      - VSS shadow storage used / allocated / maximum vs the configured cap
      - Free space vs the documented 20 GB eviction buffer, and vs the "free >= total restore point size" restore rule
      - OS volume size vs the 200 GB default-on threshold
      - Other VSS providers (third-party backup/rollback tools share the same cap)
      - VSS writer health, and volsnap / VSS error events in the last N days
      - BitLocker: encryption state and whether a RecoveryPassword protector exists (restore needs it)
      - Optional EFS-encrypted file scan (EFS blocks restore) using cipher /u /n /h
      - Best-effort read of the PITR CSP values through the MDM WMI bridge (class is discovered, not assumed)
      - MDM diagnostic log errors that mention the PointInTimeRestore URI

    It does NOT change configuration, create or delete shadow copies, or trigger a restore.
    It can't tell which VSS client created a given shadow copy (VSS doesn't record that).
    Settings > System > Recovery > Point-in-time restore stays the authoritative PITR restore point list.
    It doesn't read any BitLocker recovery password. It records protector types only.

.PARAMETER OutputPath
    Folder for the CSV report and transcript. Default: $env:TEMP\PITR-Readiness

.PARAMETER EventDays
    How many days of volsnap/VSS/MDM events to scan. Default: 7

.PARAMETER ScanEfs
    Also run 'cipher /u /n /h' to list EFS-encrypted files on local drives. Can take several minutes on large disks.

.PARAMETER ExpectedMaxDiskUsageMB
    Optional. The SetMaxDiskUsage value you deployed via Intune (2048-51200). Used to flag a mismatch against vssadmin's Maximum.

.EXAMPLE
    .\Get-PointInTimeRestoreReadiness.ps1
    Standard audit, CSV written to $env:TEMP\PITR-Readiness.

.EXAMPLE
    .\Get-PointInTimeRestoreReadiness.ps1 -ScanEfs -ExpectedMaxDiskUsageMB 20480 -EventDays 14 -OutputPath C:\Temp\PITR
    Full audit including EFS scan and cap-mismatch check.

.NOTES
    Requires: Windows 11 (runs on older builds too, where it reports "not eligible"), Windows PowerShell 5.1 or PowerShell 7.
    Run as: local Administrator (vssadmin, Get-BitLockerVolume and the MDM WMI bridge need elevation).
    Safe: read-only. Suitable for Intune Remediations detection or proactive fleet sampling.
    Sources: learn.microsoft.com/windows/configuration/point-in-time-restore (Jun 2026),
             learn.microsoft.com/windows/client-management/mdm/recovery-csp (Jun 2026).
    The "SameAsRestoreRule" and 20 GB checks model Microsoft's documented rules. Real behaviour can differ on edge cases.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $env:TEMP 'PITR-Readiness'),
    [ValidateRange(1,90)][int]$EventDays = 7,
    [switch]$ScanEfs,
    [ValidateRange(0,51200)][int]$ExpectedMaxDiskUsageMB = 0
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
    param([string]$Check, [string]$Status, [string]$Value, [string]$Detail)
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; Check = $Check; Status = $Status; Value = $Value; Detail = $Detail
    })
    Write-Status -Message ("{0}: {1} {2}" -f $Check, $Value, $(if ($Detail) { "- $Detail" } else { '' })) -Status $Status
}

# Parse a vssadmin size string such as "12.5 GB (5%)" or "UNBOUNDED" into bytes (or -1)
function ConvertFrom-VssSize {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -match 'UNBOUNDED') { return -1 }
    if ($Text -match '([\d\.,]+)\s*(B|KB|MB|GB|TB)') {
        $num = [double]::Parse(($Matches[1] -replace ',', ''), [Globalization.CultureInfo]::InvariantCulture)
        $mult = switch ($Matches[2]) { 'B' {1} 'KB' {1KB} 'MB' {1MB} 'GB' {1GB} 'TB' {1TB} }
        return [int64]($num * $mult)
    }
    return $null
}

# ───────────────────────── Preflight ─────────────────────────
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcript = Join-Path $OutputPath "PITR-Readiness-$env:COMPUTERNAME-$stamp.log"
try { Start-Transcript -Path $transcript -Force | Out-Null } catch { Write-Status "Transcript not started: $($_.Exception.Message)" 'WARN' }

Write-Status "Point-in-time restore readiness audit on $env:COMPUTERNAME"
$sysDrive = $env:SystemDrive          # e.g. C:
$driveLetter = $sysDrive.TrimEnd(':')

# ───────────────────────── Detect: platform ─────────────────────────
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
$ubr = 0
if ($cv.PSObject.Properties.Name -contains 'UBR') { $ubr = [int]$cv.UBR }
$edition = [string]$cv.EditionID
$display = ''
if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $display = [string]$cv.DisplayVersion }
$buildText = "$build.$ubr ($display, $edition)"

$eligible = $false
if (($build -eq 26100 -or $build -eq 26200) -and $ubr -ge 8737) {
    $eligible = $true
    Add-Result 'OS build' 'OK' $buildText 'Meets Recovery CSP PointInTimeRestore minimum'
} elseif ($build -gt 26200) {
    $eligible = $true
    Add-Result 'OS build' 'WARN' $buildText 'Newer than documented builds - confirm applicability on the Recovery CSP page'
} elseif ($build -eq 26100 -or $build -eq 26200) {
    Add-Result 'OS build' 'ERROR' $buildText 'Below 26100.8737 / 26200.8737 - CSP not applicable, install the current cumulative update'
} else {
    Add-Result 'OS build' 'ERROR' $buildText 'PITR requires Windows 11 24H2/25H2 or later'
}

switch -Regex ($edition) {
    '^Enterprise' { Add-Result 'Edition' 'OK'   $edition 'All four settings configurable (frequency/retention are Enterprise-only per Learn)' }
    '^Education'  { Add-Result 'Edition' 'WARN' $edition 'CSP lists Education, Learn config page does not - verify frequency/retention apply' }
    '^Professional' { Add-Result 'Edition' 'WARN' $edition 'Enable + max usage only; frequency/retention not configurable on Pro per Learn' }
    '^Core'       { Add-Result 'Edition' 'WARN' $edition 'Home edition - not manageable via Intune CSP' }
    default       { Add-Result 'Edition' 'INFO' $edition 'Unrecognised edition ID' }
}

# ───────────────────────── Detect: management state ─────────────────────────
$cs = Get-CimInstance Win32_ComputerSystem
$domainJoined = [bool]$cs.PartOfDomain
$dsreg = @()
try { $dsreg = & dsregcmd.exe /status 2>$null } catch { $dsreg = @() }
$aadJoined = [bool]($dsreg | Select-String -Pattern 'AzureAdJoined\s*:\s*YES' -Quiet)
$mdmEnrolled = $false
try {
    $mdmEnrolled = [bool](Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop |
        Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains 'ProviderID' } |
        Where-Object { (Get-ItemProperty $_.PSPath).ProviderID -eq 'MS DM Server' })
} catch { $mdmEnrolled = $false }

$managed = ($edition -match '^(Enterprise|Education)') -or $domainJoined -or $mdmEnrolled
Add-Result 'Management state' 'INFO' ("Managed={0}; DomainJoined={1}; EntraJoined={2}; IntuneMDM={3}" -f $managed, $domainJoined, $aadJoined, $mdmEnrolled) `
    $(if ($managed) { 'PITR is OFF by default until 26H2 unless policy enables it' } else { 'PITR is ON by default if OS volume >= 200 GB' })

# ───────────────────────── Detect: WinRE ─────────────────────────
try {
    $re = & reagentc.exe /info 2>&1 | Out-String
    if ($re -match 'Windows RE status:\s*Enabled') { Add-Result 'WinRE' 'OK' 'Enabled' 'Restore UI reachable' }
    elseif ($re -match 'Windows RE status:\s*Disabled') { Add-Result 'WinRE' 'ERROR' 'Disabled' 'No way to reach PITR restore UI - run reagentc /enable (see QuickMachineRecovery-B Fix 2)' }
    else { Add-Result 'WinRE' 'WARN' 'Unknown' 'Could not parse reagentc /info output' }
} catch { Add-Result 'WinRE' 'WARN' 'Error' $_.Exception.Message }

# ───────────────────────── Detect: OS volume and space ─────────────────────────
$vol = Get-Volume -DriveLetter $driveLetter
$sizeGB = [math]::Round($vol.Size / 1GB, 1)
$freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
Add-Result 'OS volume size' $(if ($sizeGB -ge 200) { 'OK' } else { 'INFO' }) "$sizeGB GB" `
    $(if ($sizeGB -ge 200) { 'Meets 200 GB default-on threshold (unmanaged devices)' } else { 'Below 200 GB - never on by default, can be enabled explicitly' })
Add-Result 'Free space' $(if ($freeGB -gt 30) { 'OK' } elseif ($freeGB -gt 20) { 'WARN' } else { 'ERROR' }) "$freeGB GB" `
    $(if ($freeGB -le 20) { 'At/below 20 GB buffer - restore points are evicted oldest-first every cycle' } elseif ($freeGB -le 30) { 'Close to the 20 GB eviction buffer' } else { '' })

# ───────────────────────── Detect: restore points (VSS) ─────────────────────────
$osVolId = (Get-CimInstance Win32_Volume -Filter "DriveLetter='$sysDrive'").DeviceID
$shadows = @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { $_.VolumeName -eq $osVolId } | Sort-Object InstallDate)
if ($shadows.Count -eq 0) {
    Add-Result 'Restore points (VSS shadows on OS volume)' $(if ($managed) { 'WARN' } else { 'ERROR' }) '0' `
        'No shadow copies - feature off, not yet captured, or evicted'
} else {
    $oldest = $shadows[0].InstallDate
    $newest = $shadows[-1].InstallDate
    $spanH = [math]::Round(($newest - $oldest).TotalHours, 1)
    $ageNewestH = [math]::Round(((Get-Date) - $newest).TotalHours, 1)
    Add-Result 'Restore points (VSS shadows on OS volume)' 'OK' "$($shadows.Count)" `
        "Oldest $oldest; newest $newest (${ageNewestH}h ago); span ${spanH}h. Shadows from all VSS clients - confirm in Settings UI"
    if ($ageNewestH -gt 48) { Add-Result 'Newest restore point age' 'WARN' "${ageNewestH}h" 'No capture in 48h+ - check device uptime, VSS writers, free space' }
}

# ───────────────────────── Detect: shadow storage ─────────────────────────
$usedBytes = $null; $maxBytes = $null
try {
    $ss = & vssadmin.exe list shadowstorage "/for=$sysDrive" 2>&1 | Out-String
    $usedLine = ($ss -split "`r?`n") | Where-Object { $_ -match 'Used Shadow Copy Storage space' } | Select-Object -First 1
    $allocLine = ($ss -split "`r?`n") | Where-Object { $_ -match 'Allocated Shadow Copy Storage space' } | Select-Object -First 1
    $maxLine = ($ss -split "`r?`n") | Where-Object { $_ -match 'Maximum Shadow Copy Storage space' } | Select-Object -First 1
    if ($maxLine) {
        $usedBytes = ConvertFrom-VssSize ($usedLine -replace '^.*?:', '')
        $maxBytes = ConvertFrom-VssSize ($maxLine -replace '^.*?:', '')
        $usedTxt = ($usedLine -replace '^.*?:', '').Trim()
        $allocTxt = ($allocLine -replace '^.*?:', '').Trim()
        $maxTxt = ($maxLine -replace '^.*?:', '').Trim()
        Add-Result 'VSS shadow storage' 'INFO' "Used $usedTxt / Allocated $allocTxt / Max $maxTxt" 'Cap is shared by all VSS consumers on the volume'
        if ($maxBytes -gt 0 -and $null -ne $usedBytes -and $usedBytes -ge (0.9 * $maxBytes)) {
            Add-Result 'VSS cap pressure' 'WARN' ("{0:N0}% used" -f (100 * $usedBytes / $maxBytes)) 'History will be truncated - consider raising SetMaxDiskUsage'
        }
        if ($ExpectedMaxDiskUsageMB -gt 0 -and $maxBytes -gt 0) {
            $maxMB = [math]::Round($maxBytes / 1MB)
            $delta = [math]::Abs($maxMB - $ExpectedMaxDiskUsageMB)
            Add-Result 'Cap vs deployed SetMaxDiskUsage' $(if ($delta -le ($ExpectedMaxDiskUsageMB * 0.05)) { 'OK' } else { 'WARN' }) `
                "vssadmin ${maxMB} MB vs expected $ExpectedMaxDiskUsageMB MB" 'Mismatch suggests policy not applied or overridden locally'
        }
        if ($null -ne $usedBytes -and $usedBytes -gt 0) {
            $needGB = [math]::Round($usedBytes / 1GB, 1)
            Add-Result 'Restore free-space rule' $(if ($freeGB -ge $needGB) { 'OK' } else { 'ERROR' }) "Free $freeGB GB vs restore points ~$needGB GB" `
                'Restore needs free space >= total size of all restore points'
        }
    } else {
        Add-Result 'VSS shadow storage' 'WARN' 'No association' 'No shadow storage configured for the OS volume yet'
    }
} catch { Add-Result 'VSS shadow storage' 'WARN' 'Error' $_.Exception.Message }

# ───────────────────────── Detect: providers and writers ─────────────────────────
try {
    $prov = & vssadmin.exe list providers 2>&1 | Out-String
    $names = @([regex]::Matches($prov, "Provider name:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    $third = @($names | Where-Object { $_ -notmatch '^Microsoft' })
    Add-Result 'VSS providers' $(if ($third.Count -gt 0) { 'WARN' } else { 'OK' }) ($names -join '; ') `
        $(if ($third.Count -gt 0) { 'Non-Microsoft provider present - shares the VSS cap; Microsoft advises against combining with other VSS backup tools' } else { '' })
} catch { Add-Result 'VSS providers' 'WARN' 'Error' $_.Exception.Message }

try {
    $wr = & vssadmin.exe list writers 2>&1 | Out-String
    $blocks = $wr -split "Writer name:" | Select-Object -Skip 1
    $bad = @()
    foreach ($b in $blocks) {
        $n = ($b -split "`r?`n")[0].Trim().Trim("'")
        if ($b -notmatch 'State:\s*\[1\]\s*Stable' -or $b -notmatch 'Last error:\s*No error') { $bad += $n }
    }
    Add-Result 'VSS writers' $(if ($bad.Count -gt 0) { 'WARN' } else { 'OK' }) "$($blocks.Count) writers, $($bad.Count) unhealthy" ($bad -join '; ')
} catch { Add-Result 'VSS writers' 'WARN' 'Error' $_.Exception.Message }

# ───────────────────────── Detect: events ─────────────────────────
$since = (Get-Date).AddDays(-$EventDays)
$volsnap = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'volsnap'; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.Level -le 3 })
$vssErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'VSS'; Level = 2; StartTime = $since } -ErrorAction SilentlyContinue)
Add-Result "volsnap warnings/errors (${EventDays}d)" $(if ($volsnap.Count -gt 0) { 'WARN' } else { 'OK' }) "$($volsnap.Count)" `
    $(if ($volsnap.Count -gt 0) { 'IDs: ' + (($volsnap | Select-Object -ExpandProperty Id -Unique) -join ',') + ' - diff-area failures can delete ALL restore points' } else { '' })
Add-Result "VSS errors (${EventDays}d)" $(if ($vssErr.Count -gt 0) { 'WARN' } else { 'OK' }) "$($vssErr.Count)" `
    $(if ($vssErr.Count -gt 0) { 'IDs: ' + (($vssErr | Select-Object -ExpandProperty Id -Unique) -join ',') } else { '' })

$mdmLog = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin'
$mdmErr = @(Get-WinEvent -FilterHashtable @{ LogName = $mdmLog; Level = 2; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'PointInTimeRestore' })
Add-Result 'MDM errors for PointInTimeRestore URI' $(if ($mdmErr.Count -gt 0) { 'ERROR' } else { 'OK' }) "$($mdmErr.Count)" `
    $(if ($mdmErr.Count -gt 0) { 'Check build, data type (Boolean vs Integer) and URI case in the Intune custom profile' } else { '' })

# ───────────────────────── Detect: CSP values via MDM WMI bridge (best effort) ─────────────────────────
try {
    $cls = @(Get-CimClass -Namespace 'root\cimv2\mdm\dmmap' -ErrorAction Stop | Where-Object { $_.CimClassName -match 'Recovery.*PointInTimeRestore' })
    if ($cls.Count -eq 0) {
        Add-Result 'CSP values (MDM bridge)' 'INFO' 'Class not found' 'No PointInTimeRestore WMI bridge class on this build - use Settings UI to confirm values'
    } else {
        foreach ($c in $cls) {
            $inst = @(Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName $c.CimClassName -ErrorAction SilentlyContinue)
            foreach ($i in $inst) {
                $props = $i.CimInstanceProperties | Where-Object { $_.Name -match 'Enable|Max|Frequency|Retention' } |
                    ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }
                Add-Result 'CSP values (MDM bridge)' 'INFO' $c.CimClassName ($props -join '; ')
            }
            if ($inst.Count -eq 0) { Add-Result 'CSP values (MDM bridge)' 'INFO' $c.CimClassName 'Class present, no instance (not configured via MDM)' }
        }
    }
} catch { Add-Result 'CSP values (MDM bridge)' 'INFO' 'Unavailable' $_.Exception.Message }

# ───────────────────────── Detect: BitLocker ─────────────────────────
try {
    $bl = Get-BitLockerVolume -MountPoint $sysDrive -ErrorAction Stop
    $types = @($bl.KeyProtector | ForEach-Object { [string]$_.KeyProtectorType })
    $hasRP = $types -contains 'RecoveryPassword'
    if ([string]$bl.VolumeStatus -eq 'FullyDecrypted') {
        Add-Result 'BitLocker' 'INFO' 'Not encrypted' 'No recovery key needed at WinRE'
    } elseif ($hasRP) {
        Add-Result 'BitLocker' 'OK' ("{0}; protectors: {1}" -f $bl.VolumeStatus, ($types -join ',')) 'RecoveryPassword present - confirm it is escrowed and retrievable by helpdesk'
    } else {
        Add-Result 'BitLocker' 'ERROR' ("{0}; protectors: {1}" -f $bl.VolumeStatus, ($types -join ',')) 'No RecoveryPassword protector - WinRE restore will be blocked (B runbook Fix 5)'
    }
} catch { Add-Result 'BitLocker' 'WARN' 'Unavailable' $_.Exception.Message }

# ───────────────────────── Detect: EFS (optional) ─────────────────────────
if ($ScanEfs) {
    Write-Status 'Scanning for EFS-encrypted files (cipher /u /n /h) - this can take a while...'
    try {
        $efs = & cipher.exe /u /n /h 2>&1
        $efsFiles = @($efs | Where-Object { $_ -match '^[A-Za-z]:\\' })
        $efsOnOs = @($efsFiles | Where-Object { $_ -like "$sysDrive\*" })
        Add-Result 'EFS-encrypted files on OS volume' $(if ($efsOnOs.Count -gt 0) { 'WARN' } else { 'OK' }) "$($efsOnOs.Count)" `
            $(if ($efsOnOs.Count -gt 0) { 'Changed EFS files block restore. First: ' + (($efsOnOs | Select-Object -First 3) -join ' | ') } else { '' })
    } catch { Add-Result 'EFS-encrypted files on OS volume' 'WARN' 'Scan failed' $_.Exception.Message }
} else {
    Add-Result 'EFS-encrypted files on OS volume' 'INFO' 'Not scanned' 'Re-run with -ScanEfs to check'
}

# ───────────────────────── Validate / Report ─────────────────────────
$errors = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
$verdict = if (-not $eligible) { 'NOT ELIGIBLE' }
           elseif ($errors -gt 0) { 'NOT READY' }
           elseif ($shadows.Count -eq 0) { 'NO RESTORE POINTS' }
           elseif ($warns -gt 0) { 'READY WITH WARNINGS' }
           else { 'READY' }
Add-Result 'Overall verdict' $(switch ($verdict) { 'READY' {'OK'} 'READY WITH WARNINGS' {'WARN'} default {'ERROR'} }) $verdict "$errors error(s), $warns warning(s)"

$csv = Join-Path $OutputPath "PITR-Readiness-$env:COMPUTERNAME-$stamp.csv"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "CSV report: $csv" 'OK'
try { Stop-Transcript | Out-Null } catch { }

# Intune Remediations-friendly exit code: 0 = ready (with or without warnings), 1 = not ready
if ($verdict -in @('READY', 'READY WITH WARNINGS')) { exit 0 } else { exit 1 }
