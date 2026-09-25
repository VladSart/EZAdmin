<#
.SYNOPSIS
    Read-only health audit for Windows Event Forwarding (WEF) collectors and sources.

.DESCRIPTION
    Detects whether the local machine is a Windows Event Collector (WEC), a forwarding
    source, or both, and checks the conditions that most often break source-initiated
    event forwarding:

    Collector checks
      - Wecsvc / WinRM service state, start mode, and whether they share a svchost PID
      - HTTP.sys URL ACL for http://+:5985/wsman/ (and 5986 if reserved) includes the
        Wecsvc service SID (KB 4494462 - Event 105 / error 2150859027 on sources)
      - WinRM listener presence
      - Each subscription: enabled state, type, delivery mode, content format,
        destination log, source counts (Active / Inactive / other), stale heartbeats
      - ForwardedEvents (and other destination logs) size vs maximum, oldest event age

    Source checks
      - SubscriptionManager GPO registry value(s) present and well-formed
      - WinRM service running (the forwarder lives inside WinRM)
      - Test-WSMan to the collector parsed from policy (or -CollectorFqdn)
      - Recent Microsoft-Windows-Forwarding/Operational errors (e.g. Event 105)
      - NETWORK SERVICE read access to the Security channel (channel SDDL or
        Event Log Readers membership)

    Does NOT: change any configuration, create or modify subscriptions, test HTTPS
    certificate mapping, or validate XPath queries against audit policy.

.PARAMETER Role
    Auto (default) detects from Wecsvc subscriptions / SubscriptionManager policy.
    Collector or Source forces a role. Both runs both sets of checks.

.PARAMETER CollectorFqdn
    Collector FQDN to test from a source. If omitted, parsed from the SubscriptionManager policy.

.PARAMETER StaleHeartbeatHours
    Sources whose LastHeartbeatTime is older than this are flagged. Default 24.

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP.

.EXAMPLE
    .\Get-WEFHealth.ps1
    Auto-detect role and audit.

.EXAMPLE
    .\Get-WEFHealth.ps1 -Role Source -CollectorFqdn wec01.contoso.com -OutputPath C:\Temp

.NOTES
    Run elevated (wecutil, netsh urlacl and the Security channel descriptor need admin).
    Read-only and safe for production. Windows PowerShell 5.1 or PowerShell 7.
    wecutil / netsh output is parsed as English text; localized OSes may yield UNKNOWN rows.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Collector', 'Source', 'Both')]
    [string]$Role = 'Auto',
    [string]$CollectorFqdn,
    [ValidateRange(1, 8760)]
    [int]$StaleHeartbeatHours = 24,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Check, [string]$Status, [string]$Detail, [string]$Fix = '')
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; Area = $Area; Check = $Check
        Status = $Status; Detail = $Detail; SuggestedFix = $Fix
    })
    Write-Status -Message "$Area | $Check : $Detail" -Status $Status
}

$WinRMSid  = 'S-1-5-80-569256582-2953403351-2909559716-1301513147-412116970'
$WecsvcSid = 'S-1-5-80-4059739203-877974739-1245631912-527174227-2996563517'
$SmKey     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager'

# ---------------- Preflight / Detect ----------------
Write-Status "Get-WEFHealth starting on $env:COMPUTERNAME (Role=$Role)"
$hasWecutil = [bool](Get-Command wecutil.exe -ErrorAction SilentlyContinue)
$subscriptions = @()
if ($hasWecutil) {
    try { $subscriptions = @(& wecutil.exe es 2>$null | Where-Object { $_ -and $_.Trim() }) } catch { $subscriptions = @() }
}
$smValues = @()
if (Test-Path $SmKey) {
    $props = Get-ItemProperty -Path $SmKey
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -notlike 'PS*') { $smValues += [string]$p.Value }
    }
}

$doCollector = $false; $doSource = $false
switch ($Role) {
    'Collector' { $doCollector = $true }
    'Source'    { $doSource = $true }
    'Both'      { $doCollector = $true; $doSource = $true }
    default {
        $wecSvc = Get-Service -Name Wecsvc -ErrorAction SilentlyContinue
        if ($subscriptions.Count -gt 0 -or ($wecSvc -and $wecSvc.Status -eq 'Running')) { $doCollector = $true }
        if ($smValues.Count -gt 0 -or $CollectorFqdn) { $doSource = $true }
        if (-not $doCollector -and -not $doSource) {
            Add-Result 'Detect' 'Role' 'WARN' 'No subscriptions and no SubscriptionManager policy found - machine is neither collector nor source' 'Use -Role to force checks'
        }
    }
}

# ---------------- Collector ----------------
if ($doCollector) {
    $svc = @(Get-CimInstance Win32_Service -Filter "Name='Wecsvc' OR Name='WinRM'")
    $wec = $svc | Where-Object { $_.Name -eq 'Wecsvc' } | Select-Object -First 1
    $wrm = $svc | Where-Object { $_.Name -eq 'WinRM' }  | Select-Object -First 1
    foreach ($s in @($wec, $wrm)) {
        if ($null -eq $s) { continue }
        $st = if ($s.State -eq 'Running' -and $s.StartMode -eq 'Auto') { 'OK' } else { 'ERROR' }
        Add-Result 'Collector' "Service $($s.Name)" $st "State=$($s.State) StartMode=$($s.StartMode) PID=$($s.ProcessId)" 'wecutil qc /q ; winrm quickconfig'
    }
    $split = $false
    if ($wec -and $wrm -and $wec.ProcessId -gt 0 -and $wrm.ProcessId -gt 0 -and $wec.ProcessId -ne $wrm.ProcessId) { $split = $true }
    Add-Result 'Collector' 'Svchost split' 'INFO' ("Wecsvc and WinRM in separate processes: {0}" -f $split)

    foreach ($url in @('http://+:5985/wsman/', 'https://+:5986/wsman/')) {
        $txt = (& netsh.exe http show urlacl url=$url 2>$null) -join "`n"
        if ($txt -notmatch 'Reserved URL') {
            $st = if ($url -like 'http:*') { 'ERROR' } else { 'INFO' }
            Add-Result 'Collector' "URL ACL $url" $st 'No reservation found' 'winrm quickconfig (HTTP) or create HTTPS listener'
            continue
        }
        $hasWec = ($txt -match [regex]::Escape($WecsvcSid)) -or ($txt -match 'NT SERVICE\\Wecsvc')
        if ($hasWec) {
            Add-Result 'Collector' "URL ACL $url" 'OK' 'Wecsvc SID present'
        } else {
            $st = if ($split) { 'ERROR' } else { 'WARN' }
            Add-Result 'Collector' "URL ACL $url" $st 'Wecsvc SID missing (sources will log Event 105 / 2150859027 when services are split)' 'See WindowsEventForwarding-B.md Fix 2 (KB 4494462)'
        }
    }

    $listeners = (& winrm.cmd enumerate winrm/config/listener 2>$null) -join "`n"
    if ($listeners -match 'Transport\s*=\s*HTTP') { Add-Result 'Collector' 'WinRM listener' 'OK' 'Listener present' }
    else { Add-Result 'Collector' 'WinRM listener' 'ERROR' 'No WinRM listener enumerated' 'winrm quickconfig or WinRM GPO' }

    $destLogs = @{}
    if ($subscriptions.Count -eq 0) {
        Add-Result 'Collector' 'Subscriptions' 'WARN' 'No subscriptions configured'
    }
    foreach ($sub in $subscriptions) {
        $cfg = (& wecutil.exe gs "$sub" 2>$null) -join "`n"
        $enabled = if ($cfg -match '(?m)^\s*Enabled:\s*(\S+)') { $Matches[1] } else { 'UNKNOWN' }
        $type    = if ($cfg -match '(?m)^\s*SubscriptionType:\s*(\S+)') { $Matches[1] } else { 'UNKNOWN' }
        $mode    = if ($cfg -match '(?m)^\s*ConfigurationMode:\s*(\S+)') { $Matches[1] } else { 'UNKNOWN' }
        $format  = if ($cfg -match '(?m)^\s*ContentFormat:\s*(\S+)') { $Matches[1] } else { 'UNKNOWN' }
        $logFile = if ($cfg -match '(?m)^\s*LogFile:\s*(.+)$') { $Matches[1].Trim() } else { 'ForwardedEvents' }
        $destLogs[$logFile] = $true
        $st = if ($enabled -eq 'true') { 'OK' } elseif ($enabled -eq 'UNKNOWN') { 'WARN' } else { 'ERROR' }
        Add-Result 'Subscription' "$sub config" $st "Enabled=$enabled Type=$type Mode=$mode Format=$format Log=$logFile" 'wecutil ss <sub> /e:true'

        $rt = @(& wecutil.exe gr "$sub" 2>$null)
        $active = 0; $inactive = 0; $other = 0; $stale = 0; $current = $null
        $cutoff = (Get-Date).AddHours(-1 * $StaleHeartbeatHours)
        foreach ($line in $rt) {
            if ($line -match '^\s*EventSource\[\d+\]') { $current = @{} ; continue }
            if ($null -ne $current -and $line -match '^\s*RunTimeStatus:\s*(\S+)') {
                switch ($Matches[1]) { 'Active' { $active++ } 'Inactive' { $inactive++ } default { $other++ } }
            }
            if ($null -ne $current -and $line -match '^\s*LastHeartbeatTime:\s*(.+)$') {
                $hb = $null
                if ([datetime]::TryParse($Matches[1].Trim(), [ref]$hb)) { if ($hb -lt $cutoff) { $stale++ } }
            }
        }
        $total = $active + $inactive + $other
        $st = if ($total -eq 0) { 'WARN' } elseif ($inactive -gt 0 -or $stale -gt 0) { 'WARN' } else { 'OK' }
        Add-Result 'Subscription' "$sub sources" $st "Total=$total Active=$active Inactive=$inactive Other=$other StaleHeartbeat(>${StaleHeartbeatHours}h)=$stale" 'wecutil gr <sub> ; wecutil rs <sub>'
        if ($total -gt 1000) {
            Add-Result 'Subscription' "$sub scale" 'WARN' "$total lifetime sources - Event Viewer UI may hang" 'Split subscription by role/OU (WindowsEventForwarding-A.md Playbook 3/4)'
        }
        if ($mode -eq 'MinLatency' -and $total -gt 500) {
            Add-Result 'Subscription' "$sub load" 'WARN' 'MinLatency on a large source set increases collector load' 'Use Normal/Custom for bulk sources'
        }
    }
    if ($destLogs.Count -eq 0) { $destLogs['ForwardedEvents'] = $true }
    foreach ($ln in $destLogs.Keys) {
        try {
            $li = Get-WinEvent -ListLog $ln
            $pct = if ($li.MaximumSizeInBytes -gt 0 -and $li.FileSize) { [math]::Round(100 * $li.FileSize / $li.MaximumSizeInBytes, 1) } else { 0 }
            $oldest = $null
            try { $oldest = (Get-WinEvent -LogName $ln -Oldest -MaxEvents 1 -ErrorAction Stop).TimeCreated } catch { $oldest = $null }
            $ageH = if ($oldest) { [math]::Round(((Get-Date) - $oldest).TotalHours, 1) } else { 'n/a' }
            $maxMB = [math]::Round($li.MaximumSizeInBytes / 1MB, 0)
            $st = if ($maxMB -le 64 -and $li.RecordCount -gt 0) { 'WARN' } else { 'OK' }
            Add-Result 'Destination' "Log $ln" $st "Records=$($li.RecordCount) Max=${maxMB}MB Used=$pct% Mode=$($li.LogMode) OldestAgeHours=$ageH" "wevtutil sl `"$ln`" /ms:<bytes>"
        } catch {
            Add-Result 'Destination' "Log $ln" 'ERROR' "Cannot read log: $($_.Exception.Message)"
        }
    }
}

# ---------------- Source ----------------
if ($doSource) {
    if ($smValues.Count -eq 0) {
        Add-Result 'Source' 'SubscriptionManager policy' 'ERROR' 'No SubscriptionManager value - GPO not applied' 'gpupdate /force ; check GPO link/filtering'
    }
    foreach ($v in $smValues) {
        $ok = $v -match '^Server=https?://[^/:,]+\.[^/:,]+:\d+/wsman/SubscriptionManager/WEC'
        $st = if ($ok) { 'OK' } else { 'WARN' }
        Add-Result 'Source' 'SubscriptionManager policy' $st $v 'Expected Server=http://<FQDN>:5985/wsman/SubscriptionManager/WEC,Refresh=60'
        if (-not $CollectorFqdn -and $v -match '^Server=https?://([^/:,]+)') { $CollectorFqdn = $Matches[1] }
    }
    $w = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($w -and $w.Status -eq 'Running') { Add-Result 'Source' 'WinRM service' 'OK' "Running ($($w.StartType))" }
    else { Add-Result 'Source' 'WinRM service' 'ERROR' 'WinRM not running - forwarder cannot run' 'Set WinRM Automatic via GPO' }

    if ($CollectorFqdn) {
        try {
            $null = Test-WSMan -ComputerName $CollectorFqdn -ErrorAction Stop
            Add-Result 'Source' "Test-WSMan $CollectorFqdn" 'OK' 'Collector WS-Man reachable'
        } catch {
            Add-Result 'Source' "Test-WSMan $CollectorFqdn" 'ERROR' $_.Exception.Message.Split("`n")[0] 'Check DNS, firewall 5985, collector listener (WinRM-B.md)'
        }
    }

    try {
        $fwd = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Forwarding/Operational'; StartTime = (Get-Date).AddDays(-2) } -ErrorAction Stop)
        $errs = @($fwd | Where-Object { $_.Id -eq 105 -or $_.Level -le 2 })
        if ($errs.Count -gt 0) {
            $msg = ($errs[0].Message -replace '\s+', ' ')
            if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) }
            $hint = if ($msg -match '2150859027') { 'Collector URL ACL - WindowsEventForwarding-B.md Fix 2' } else { 'See WindowsEventForwarding-B.md Triage' }
            Add-Result 'Source' 'Forwarding/Operational (48h)' 'ERROR' "$($errs.Count) error events; latest Id $($errs[0].Id): $msg" $hint
        } else {
            Add-Result 'Source' 'Forwarding/Operational (48h)' 'OK' "$($fwd.Count) events, no errors"
        }
    } catch {
        Add-Result 'Source' 'Forwarding/Operational (48h)' 'INFO' 'No events in last 48h (forwarder may never have been configured)'
    }

    $secOk = $false
    $ca = (& wevtutil.exe gl security 2>$null) -join "`n"
    if ($ca -match 'channelAccess:\s*(\S+)') {
        if ($Matches[1] -match '\(A;;0x[0-9a-fA-F]*[13579bdfBDF];;;S-1-5-20\)' -or $Matches[1] -match '\(A;;0x1;;;S-1-5-20\)') { $secOk = $true }
    }
    if (-not $secOk) {
        try {
            $members = @(Get-LocalGroupMember -SID 'S-1-5-32-573' -ErrorAction Stop)
            if ($members | Where-Object { "$($_.SID)" -eq 'S-1-5-20' }) { $secOk = $true }
        } catch {
            $txt = (& net.exe localgroup 'Event Log Readers' 2>$null) -join "`n"
            if ($txt -match 'NETWORK SERVICE') { $secOk = $true }
        }
    }
    if ($secOk) { Add-Result 'Source' 'Security channel access (NETWORK SERVICE)' 'OK' 'Readable via channel SDDL or Event Log Readers' }
    else { Add-Result 'Source' 'Security channel access (NETWORK SERVICE)' 'WARN' 'NETWORK SERVICE cannot read Security - Security events will not forward' 'WindowsEventForwarding-B.md Fix 5' }
}

# ---------------- Report ----------------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$csv = Join-Path $OutputPath ("WEFHealth-{0}-{1:yyyyMMdd-HHmmss}.csv" -f $env:COMPUTERNAME, (Get-Date))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$err  = @($results | Where-Object { $_.Status -eq 'ERROR' }).Count
$warn = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
$final = if ($err) { 'ERROR' } elseif ($warn) { 'WARN' } else { 'OK' }
Write-Status "Done. Errors=$err Warnings=$warn. Report: $csv" $final
