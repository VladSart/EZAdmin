<#
.SYNOPSIS
    Read-only health check for volume-licensed Office (LTSC 2024/2021, 2019) activation via KMS, ADBA or MAK.

.DESCRIPTION
    Uses the Windows Software Protection Platform CIM classes directly (no OSPP.VBS / VBScript dependency),
    so it keeps working after the VBScript Feature on Demand is disabled.

    Client mode (default) collects:
      - Click-to-Run ProductReleaseIds / channel, classifying the install as Volume, Retail or Subscription
      - Every Office licence row with an installed key (application ID 0ff1ce15-...): channel, status, grace,
        configured and discovered KMS host
      - _vlmcs._tcp SRV records for the computer's domain and a TCP 1688 test to the effective KMS host
      - Recent SPP events 8198/12288/12289 and the last error code seen
    Host mode (-HostMode) additionally reports Office KMS host rows (CSVLK), current Office client count,
    firewall rule state and recent Key Management Service log activity.

    Does NOT install keys, change hosts or activate anything. Does not cover subscription Microsoft 365 Apps
    (see Get-M365AppsActivationDiagnostics.ps1) or Windows OS activation (Get-VolumeActivationHealth.ps1).

.PARAMETER HostMode
    Also inspect this machine as an Office KMS host.

.PARAMETER KmsHost
    Optional KMS host FQDN to test on TCP 1688 instead of the configured/discovered one.

.PARAMETER EventDays
    How many days of SPP events to inspect. Default 7.

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP.

.EXAMPLE
    .\Get-OfficeVolumeActivationHealth.ps1
    Client check; writes OfficeVLHealth_<computer>_<timestamp>.csv to %TEMP%.

.EXAMPLE
    .\Get-OfficeVolumeActivationHealth.ps1 -HostMode -OutputPath C:\Temp
    Run on a KMS host to include Office host licence rows and client count.

.NOTES
    Requires: Windows 8.1 / Server 2012 R2 or later, PowerShell 5.1+.
    Run as:   standard user works for most checks; administrator recommended for full event access.
    Safety:   read-only.
#>
[CmdletBinding()]
param(
    [switch]$HostMode,
    [string]$KmsHost,
    [ValidateRange(1,90)][int]$EventDays = 7,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

$OfficeAppId = '0ff1ce15-a989-479d-af46-f275c6370663'
$StatusMap = @{ 0='Unlicensed'; 1='Licensed'; 2='OOBGrace'; 3='OOTGrace'; 4='NonGenuineGrace'; 5='Notification'; 6='ExtendedGrace' }
$ErrorMap = @{
    '0xC004F074' = 'No KMS host could be contacted'
    '0x8007232B' = 'DNS name does not exist (no _vlmcs SRV)'
    '0xC004F038' = 'KMS count below threshold (Office needs 5)'
    '0xC004F042' = 'KMS host cannot activate this product (VLP/CSVLK missing or older generation)'
    '0xC004C008' = 'MAK activation limit reached'
    '0xC004C020' = 'MAK activation limit reached'
    '0xC004F050' = 'Product key invalid for this product (Retail install or wrong generation)'
}
$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Item, [string]$Value, [string]$Status, [string]$Note = '')
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; Area = $Area; Item = $Item; Value = $Value; Status = $Status; Note = $Note
    })
    Write-Status -Message "$Area | $Item = $Value $(if ($Note) { "($Note)" })" -Status $Status
}

# ---------------- Preflight ----------------
$os = Get-CimInstance Win32_OperatingSystem
Add-Result 'Preflight' 'OS' "$($os.Caption) $($os.Version)" 'INFO'
if ([version]$os.Version -lt [version]'6.3') {
    Add-Result 'Preflight' 'OS support' 'Pre-8.1' 'ERROR' 'Office 2013+ on this OS may use OSPPSVC; script targets SPP'
}
try {
    $spp = Get-Service -Name sppsvc
    Add-Result 'Preflight' 'sppsvc' "$($spp.Status) / $($spp.StartType)" 'OK' 'Trigger-start service; Stopped is normal when idle'
} catch {
    Add-Result 'Preflight' 'sppsvc' 'Not found' 'ERROR'
}
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

# ---------------- Detect install ----------------
$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$releaseIds = [string](Get-Prop $c2r 'ProductReleaseIds')
if ($releaseIds) {
    Add-Result 'Install' 'ProductReleaseIds' $releaseIds 'INFO'
    Add-Result 'Install' 'UpdateChannel' ([string](Get-Prop $c2r 'UpdateChannel')) 'INFO'
    foreach ($id in ($releaseIds -split ',')) {
        $id = $id.Trim()
        if (-not $id) { continue }
        $kind = if ($id -like 'O365*' -or $id -like '*O365*') { 'Subscription' }
                elseif ($id -like '*Volume') { 'Volume' }
                elseif ($id -like '*Retail') { 'Retail' }
                else { 'Other' }
        $st = switch ($kind) { 'Volume' {'OK'} 'Retail' {'WARN'} 'Subscription' {'INFO'} default {'INFO'} }
        $note = switch ($kind) {
            'Retail' { 'GVLK/MAK cannot activate a Retail product - reinstall as *Volume (Fix 5)' }
            'Subscription' { 'Subscription product - use Activation-B.md' }
            default { '' }
        }
        Add-Result 'Install' $id $kind $st $note
    }
} else {
    Add-Result 'Install' 'Click-to-Run' 'Not detected' 'WARN' 'MSI Office or no Office; licence rows below still apply if present'
}

# ---------------- Licence rows ----------------
$rows = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$OfficeAppId' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue)
if ($rows.Count -eq 0) {
    Add-Result 'Licence' 'Office rows with key' '0' 'ERROR' 'No Office key installed in SPP (Fix 1)'
}
$effectiveHosts = New-Object System.Collections.Generic.List[string]
foreach ($r in $rows) {
    $desc = [string](Get-Prop $r 'Description')
    $channel = if ($desc -match 'VOLUME_KMSCLIENT') { 'KMS client (GVLK)' }
               elseif ($desc -match 'VOLUME_KMS') { 'KMS host (CSVLK)' }
               elseif ($desc -match 'VOLUME_MAK') { 'MAK' }
               elseif ($desc -match 'RETAIL') { 'Retail' }
               elseif ($desc -match 'TIMEBASED|SUBSCRIPTION') { 'Time-based/Subscription' }
               else { 'Other' }
    $statusCode = [int](Get-Prop $r 'LicenseStatus')
    $statusText = if ($StatusMap.ContainsKey($statusCode)) { $StatusMap[$statusCode] } else { "Unknown($statusCode)" }
    $graceMin = Get-Prop $r 'GracePeriodRemaining'
    $graceDays = if ($null -ne $graceMin) { [math]::Round([double]$graceMin / 1440, 1) } else { $null }
    $st = if ($statusCode -eq 1) { 'OK' } else { 'ERROR' }
    Add-Result 'Licence' ([string]$r.Name) "$statusText; $channel; key *****-$($r.PartialProductKey); grace ${graceDays}d" $st

    $reason = Get-Prop $r 'LicenseStatusReason'
    if ($statusCode -ne 1 -and $null -ne $reason) {
        $hex = '0x{0:X8}' -f ([uint32]$reason)
        $meaning = if ($ErrorMap.ContainsKey($hex)) { $ErrorMap[$hex] } else { '' }
        Add-Result 'Licence' "$($r.Name) reason" $hex 'WARN' $meaning
    }
    if ($channel -eq 'KMS client (GVLK)') {
        $manual = [string](Get-Prop $r 'KeyManagementServiceMachine')
        $disc = [string](Get-Prop $r 'DiscoveredKeyManagementServiceMachineName')
        Add-Result 'KMS' "$($r.Name) manual host" $(if ($manual) { $manual } else { '(none - DNS auto-discovery)' }) 'INFO'
        Add-Result 'KMS' "$($r.Name) discovered host" $(if ($disc) { $disc } else { '(none)' }) $(if ($disc -or $manual) { 'INFO' } else { 'WARN' })
        if ($manual) { $effectiveHosts.Add($manual) } elseif ($disc) { $effectiveHosts.Add($disc) }
    }
}
$names = @($rows | ForEach-Object { [string]$_.Name })
$dupes = @($names | Group-Object | Where-Object Count -gt 1)
foreach ($d in $dupes) { Add-Result 'Licence' 'Duplicate rows' $d.Name 'WARN' 'Stray key on same product can cause banners - remove extra key' }

# ---------------- Discovery / transport ----------------
$domain = (Get-CimInstance Win32_ComputerSystem).Domain
$srvHosts = @()
try {
    $srv = @(Resolve-DnsName -Name "_vlmcs._tcp.$domain" -Type SRV -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' })
    $srvHosts = @($srv | ForEach-Object { $_.NameTarget })
    Add-Result 'Discovery' "_vlmcs._tcp.$domain" ($srvHosts -join ', ') 'OK'
} catch {
    Add-Result 'Discovery' "_vlmcs._tcp.$domain" 'No SRV record' 'WARN' 'Clients without a manual host cannot find KMS (0x8007232B)'
}
$testHosts = @()
if ($KmsHost) { $testHosts = @($KmsHost) }
elseif ($effectiveHosts.Count -gt 0) { $testHosts = @($effectiveHosts | Select-Object -Unique) }
elseif ($srvHosts.Count -gt 0) { $testHosts = @($srvHosts | Select-Object -Unique) }
foreach ($h in $testHosts) {
    try {
        $t = Test-NetConnection -ComputerName $h -Port 1688 -WarningAction SilentlyContinue
        Add-Result 'Transport' "${h}:1688" $(if ($t.TcpTestSucceeded) { 'Reachable' } else { 'Blocked/unreachable' }) $(if ($t.TcpTestSucceeded) { 'OK' } else { 'ERROR' })
    } catch {
        Add-Result 'Transport' "${h}:1688" "Test failed: $($_.Exception.Message)" 'ERROR'
    }
}

# ---------------- Events ----------------
try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='Microsoft-Windows-Security-SPP'; Id=8198,12288,12289; StartTime=(Get-Date).AddDays(-$EventDays) } -ErrorAction Stop)
    Add-Result 'Events' "SPP 8198/12288/12289 last ${EventDays}d" "$($ev.Count)" 'INFO'
    $lastErr = $ev | Where-Object { $_.Message -match '0x[0-9A-Fa-f]{8}' -and $_.Message -notmatch '0x0+\b' } | Select-Object -First 1
    if ($lastErr) {
        $code = ([regex]::Match($lastErr.Message, '0x[0-9A-Fa-f]{8}')).Value.ToUpper().Replace('0X','0x')
        $meaning = if ($ErrorMap.ContainsKey($code)) { $ErrorMap[$code] } else { 'See OSPP.VBS /ddescr:<code> or Learn' }
        Add-Result 'Events' "Last error ($($lastErr.TimeCreated))" $code 'WARN' $meaning
    }
} catch {
    Add-Result 'Events' 'SPP events' 'None found or no access' 'INFO'
}

# ---------------- Host mode ----------------
if ($HostMode) {
    $hostRows = @($rows | Where-Object { ([string](Get-Prop $_ 'Description')) -match 'VOLUME_KMS channel' })
    if ($hostRows.Count -eq 0) {
        Add-Result 'Host' 'Office KMS host rows' '0' 'ERROR' 'No Office CSVLK installed - install VLP + host key for each Office generation'
    }
    foreach ($h in $hostRows) {
        $count = Get-Prop $h 'KeyManagementServiceCurrentCount'
        $st = if ([int]$h.LicenseStatus -ne 1) { 'ERROR' } elseif ($null -ne $count -and [int]$count -lt 5) { 'WARN' } else { 'OK' }
        Add-Result 'Host' ([string]$h.Name) "Status $($StatusMap[[int]$h.LicenseStatus]); count $count" $st $(if ($st -eq 'WARN') { 'Office threshold is 5' } else { '' })
    }
    try {
        $fw = @(Get-NetFirewallRule -DisplayGroup 'Key Management Service' -ErrorAction Stop)
        Add-Result 'Host' 'Firewall KMS rules enabled' "$(@($fw | Where-Object Enabled -eq 'True').Count) of $($fw.Count)" 'INFO'
    } catch {
        Add-Result 'Host' 'Firewall KMS rule group' 'Not found' 'WARN' 'Confirm TCP 1688 inbound is allowed'
    }
    try {
        $kmsEv = @(Get-WinEvent -FilterHashtable @{ LogName='Key Management Service'; Id=12290; StartTime=(Get-Date).AddDays(-$EventDays) } -ErrorAction Stop)
        Add-Result 'Host' "KMS requests (12290) last ${EventDays}d" "$($kmsEv.Count)" 'INFO'
    } catch {
        Add-Result 'Host' 'Key Management Service log' 'No 12290 events' 'WARN' 'Host may not be receiving requests'
    }
}

# ---------------- Report ----------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csv = Join-Path $OutputPath "OfficeVLHealth_$($env:COMPUTERNAME)_$stamp.csv"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$errs = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. $errs error(s), $warns warning(s). Report: $csv" $(if ($errs) { 'ERROR' } elseif ($warns) { 'WARN' } else { 'OK' })
