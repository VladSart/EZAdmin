<#
.SYNOPSIS
    Read-only NCSI ("No Internet" false positive) diagnostic with a decoded verdict and CSV report.

.DESCRIPTION
    Collects and interprets everything that decides the Windows Network Connectivity Status
    Indicator (NCSI) verdict on this device:
      - Per-interface connectivity verdict (Get-NetConnectionProfile)
      - Hosting service state (netprofm on Windows 11 / Server 2022+, NlaSvc on older builds)
      - Probe configuration drift vs Microsoft defaults (EnableActiveProbing, probe host/path/content)
      - Policy overlay (HKLM\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator)
      - DNS resolution of the probe host through the device's own resolvers
      - HTTP probe: status code, redirect, exact content match, proxy-auth (407) detection
      - Machine (WinHTTP) proxy vs current-user proxy / PAC
      - Default routes (forced-tunnel VPN indicator)
      - Recent NCSI Operational events with ChangeReason extraction
    Produces a list of findings (OK / WARN / ERROR) and a recommended fix path mapped to NCSI-B.md.

    Does NOT change any configuration, does not restart services or adapters, and does not enable
    the NCSI Analytic log. The HTTP probe test runs in the CURRENT user's context; NCSI itself runs
    as a service, so a pass here plus a failing verdict points at proxy/auth context differences.

.PARAMETER OutputPath
    Folder for the CSV report. Defaults to $env:TEMP.

.PARAMETER ProbeTimeoutSec
    Timeout for the HTTP probe test. Default 10.

.PARAMETER EventCount
    Number of recent NCSI Operational events to inspect. Default 30.

.EXAMPLE
    .\Get-NCSIDiagnostics.ps1
    Runs all checks and writes NCSI-Diagnostics-<host>-<timestamp>.csv to %TEMP%.

.EXAMPLE
    .\Get-NCSIDiagnostics.ps1 -OutputPath C:\Temp -ProbeTimeoutSec 20

.NOTES
    Requires : Windows 10/11 or Windows Server 2016+, PowerShell 5.1+.
    Run as   : Standard user works; elevation recommended so the NCSI event log can be read.
    Safety   : Read-only. Makes one DNS query and one HTTP GET to the configured probe host.
    Companion: Windows/Troubleshooting/NCSI-B.md (hotfix) and NCSI-A.md (deep dive).
#>
[CmdletBinding()]
param(
    [string]$OutputPath = $env:TEMP,
    [ValidateRange(1, 120)][int]$ProbeTimeoutSec = 10,
    [ValidateRange(1, 500)][int]$EventCount = 30
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
    param([string]$Area, [string]$Check, [string]$Status, [string]$Value, [string]$Advice = "")
    $results.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME; Area = $Area; Check = $Check
        Status = $Status; Value = $Value; Advice = $Advice
    })
    Write-Status -Message ("{0} / {1}: {2}" -f $Area, $Check, $Value) -Status $Status
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

# ---------------- Preflight ----------------
Write-Status "NCSI diagnostics on $env:COMPUTERNAME"
$build = [Environment]::OSVersion.Version.Build
$isWin11Era = $build -ge 20348   # Server 2022 = 20348, Windows 11 = 22000+
$hostService = if ($isWin11Era) { 'netprofm' } else { 'NlaSvc' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Result 'Preflight' 'OS build' 'INFO' "$build (NCSI host service: $hostService)"
if (-not $isAdmin) { Add-Result 'Preflight' 'Elevation' 'WARN' 'Not elevated' 'Event log checks may be incomplete; re-run elevated for full results.' }
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$fixPaths = New-Object System.Collections.Generic.List[string]

# ---------------- 1. Verdict ----------------
$profiles = @()
try { $profiles = @(Get-NetConnectionProfile -ErrorAction Stop) } catch { $profiles = @() }
$anyInternet = $false
if ($profiles.Count -eq 0) {
    Add-Result 'Verdict' 'Connection profiles' 'ERROR' 'No connected profiles' 'No connected interface - this is a general network fault, not NCSI. See NetworkAdapters-B.md.'
} else {
    foreach ($p in $profiles) {
        $v4 = "$($p.IPv4Connectivity)"; $v6 = "$($p.IPv6Connectivity)"
        $isNet = ($v4 -eq 'Internet' -or $v6 -eq 'Internet')
        if ($isNet) { $anyInternet = $true }
        $st = if ($isNet) { 'OK' } else { 'WARN' }
        Add-Result 'Verdict' "Interface '$($p.InterfaceAlias)'" $st "Category=$($p.NetworkCategory) IPv4=$v4 IPv6=$v6"
    }
}

# ---------------- 2. Host service ----------------
foreach ($svcName in @('netprofm', 'NlaSvc')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { continue }
    $primary = ($svcName -eq $hostService)
    $st = 'OK'; $adv = ''
    if ($svc.Status -ne 'Running') {
        if ($primary) { $st = 'ERROR'; $adv = "Start-Service $svcName; find what disabled it (debloat/hardening script)."; $fixPaths.Add('Fix 1') }
        else { $st = 'INFO' }
    }
    Add-Result 'Service' $svcName $st ("Status={0} StartType={1}{2}" -f $svc.Status, $svc.StartType, $(if ($primary) { ' (hosts NCSI)' } else { '' })) $adv
}

# ---------------- 3. Probe config ----------------
$cfgKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
$defaults = [ordered]@{
    EnableActiveProbing   = '1'
    ActiveWebProbeHost    = 'www.msftconnecttest.com'
    ActiveWebProbePath    = 'connecttest.txt'
    ActiveWebProbeContent = 'Microsoft Connect Test'
}
$cfg = @{}
foreach ($n in $defaults.Keys) {
    $val = Get-RegValue -Path $cfgKey -Name $n
    $cfg[$n] = $val
    if ($null -eq $val) {
        Add-Result 'Config' $n 'WARN' '<missing>' 'Value absent - default behaviour assumed but verify image/baseline.'
    } elseif ("$val" -ceq $defaults[$n]) {
        Add-Result 'Config' $n 'OK' "$val"
    } else {
        if ($n -eq 'EnableActiveProbing') {
            Add-Result 'Config' $n 'ERROR' "$val" 'Active probing disabled - Microsoft advises against this. Re-enable (NCSI-B Fix 4).'
            $fixPaths.Add('Fix 4')
        } else {
            Add-Result 'Config' $n 'WARN' "$val (default: $($defaults[$n]))" 'Probe redirected - verify the internal probe server (NCSI-B Fix 5).'
            $fixPaths.Add('Fix 5')
        }
    }
}
$passive = Get-RegValue -Path $cfgKey -Name 'PassivePollPeriod'
if ($null -ne $passive) { Add-Result 'Config' 'PassivePollPeriod' 'INFO' "$passive" }
$manualProxies = Get-ItemProperty -Path "$cfgKey\ManualProxies" -ErrorAction SilentlyContinue
if ($null -ne $manualProxies) {
    $mp = ($manualProxies.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
    Add-Result 'Config' 'ManualProxies' 'INFO' $(if ($mp) { $mp } else { '<empty>' })
}

# ---------------- 4. Policy overlay ----------------
$polKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator'
if (Test-Path $polKey) {
    $pol = Get-ItemProperty -Path $polKey
    $polVals = ($pol.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
    $noActive = Get-RegValue -Path $polKey -Name 'NoActiveProbe'
    if ("$noActive" -eq '1') {
        Add-Result 'Policy' 'NoActiveProbe' 'ERROR' $polVals 'GPO/MDM turns off active tests. Remove at source (gpresult / Intune Connectivity settings) - NCSI-B Fix 4.'
        $fixPaths.Add('Fix 4')
    } else {
        Add-Result 'Policy' 'NCSI policy key' 'INFO' $(if ($polVals) { $polVals } else { '<key present, no values>' })
    }
} else {
    Add-Result 'Policy' 'NCSI policy key' 'OK' 'Not present (no policy overrides)'
}

# ---------------- 5. DNS ----------------
$probeHost = if ($cfg['ActiveWebProbeHost']) { "$($cfg['ActiveWebProbeHost'])" } else { $defaults['ActiveWebProbeHost'] }
$probePath = if ($cfg['ActiveWebProbePath']) { "$($cfg['ActiveWebProbePath'])" } else { $defaults['ActiveWebProbePath'] }
$probeContent = if ($cfg['ActiveWebProbeContent']) { "$($cfg['ActiveWebProbeContent'])" } else { $defaults['ActiveWebProbeContent'] }
$dnsOk = $false
try {
    $ans = @(Resolve-DnsName -Name $probeHost -ErrorAction Stop | Where-Object { $_.Type -eq 'A' -or $_.Type -eq 'AAAA' })
    $ips = @($ans | ForEach-Object { $_.IPAddress }) -join ', '
    if ($ans.Count -eq 0) {
        Add-Result 'DNS' $probeHost 'ERROR' 'No A/AAAA records' 'DNS filter or internal DNS not resolving probe host (NCSI-B Fix 2).'
        $fixPaths.Add('Fix 2')
    } elseif ($ips -match '(^|, )0\.0\.0\.0(,|$)|(^|, )127\.') {
        Add-Result 'DNS' $probeHost 'ERROR' "Sinkholed: $ips" 'DNS filter is blocking the probe host - allowlist msftconnecttest.com (NCSI-B Fix 2).'
        $fixPaths.Add('Fix 2')
    } else {
        $dnsOk = $true
        Add-Result 'DNS' $probeHost 'OK' $ips
    }
} catch {
    Add-Result 'DNS' $probeHost 'ERROR' "Resolution failed: $($_.Exception.Message)" 'NCSI-B Fix 2.'
    $fixPaths.Add('Fix 2')
}

# ---------------- 6. HTTP probe ----------------
$probeUrl = "http://$probeHost/$probePath"
$httpOk = $false
try {
    $resp = Invoke-WebRequest -Uri $probeUrl -UseBasicParsing -TimeoutSec $ProbeTimeoutSec -MaximumRedirection 0 -ErrorAction Stop
    $body = "$($resp.Content)"
    $shown = if ($body.Length -gt 80) { $body.Substring(0, 80) + '...' } else { $body }
    if ($resp.StatusCode -eq 200 -and $body -ceq $probeContent) {
        $httpOk = $true
        Add-Result 'HTTP' $probeUrl 'OK' "200, content matches"
    } else {
        Add-Result 'HTTP' $probeUrl 'ERROR' ("{0}, body='{1}'" -f $resp.StatusCode, $shown) 'Response rewritten (web filter / SSL inspection / captive portal) -> hotspot verdict (NCSI-B Fix 3 or Fix 5).'
        $fixPaths.Add('Fix 3')
    }
} catch {
    $code = $null
    $loc = $null
    $ex = $_.Exception
    if ($ex.PSObject.Properties['Response'] -and $null -ne $ex.Response) {
        try { $code = [int]$ex.Response.StatusCode } catch { $code = $null }
        try { $loc = $ex.Response.Headers['Location'] } catch { $loc = $null }
    }
    if ($code -eq 407) {
        Add-Result 'HTTP' $probeUrl 'ERROR' '407 Proxy Authentication Required' 'Exempt probe FQDN from proxy auth (NCSI-B Fix 3).'
    } elseif ($code -ge 300 -and $code -lt 400) {
        Add-Result 'HTTP' $probeUrl 'ERROR' "$code redirect to '$loc'" 'Captive portal / guest network or filter redirect (NCSI-A Playbook E).'
    } elseif ($null -ne $code) {
        Add-Result 'HTTP' $probeUrl 'ERROR' "HTTP $code" 'Firewall/proxy blocking probe - allow by FQDN (NCSI-B Fix 3).'
    } else {
        $st = if ($dnsOk) { 'ActiveHttpProbeFailedButDnsSucceeded pattern' } else { 'name/proxy failure' }
        Add-Result 'HTTP' $probeUrl 'ERROR' "No response: $($ex.Message) ($st)" 'TCP 80 to probe FQDN blocked or proxy unreachable (NCSI-B Fix 3).'
    }
    $fixPaths.Add('Fix 3')
}

# ---------------- 7. Proxy views ----------------
$winhttp = (netsh winhttp show proxy 2>$null | Out-String).Trim() -replace '\s+', ' '
Add-Result 'Proxy' 'WinHTTP (machine)' 'INFO' $winhttp
$ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($null -ne $ie) {
    $pe = if ($ie.PSObject.Properties['ProxyEnable']) { $ie.ProxyEnable } else { 0 }
    $ps = if ($ie.PSObject.Properties['ProxyServer']) { $ie.ProxyServer } else { '' }
    $pac = if ($ie.PSObject.Properties['AutoConfigURL']) { $ie.AutoConfigURL } else { '' }
    Add-Result 'Proxy' 'Current user' 'INFO' "ProxyEnable=$pe ProxyServer='$ps' PAC='$pac'"
    if ($httpOk -and -not $anyInternet -and (($pe -eq 1) -or $pac)) {
        Add-Result 'Proxy' 'Context mismatch' 'WARN' 'User-context probe passes via user proxy/PAC but NCSI verdict is not Internet' 'Service context may not see the same proxy or is hitting auth - check proxy logs for connecttest.txt (NCSI-B Fix 3).'
        $fixPaths.Add('Fix 3')
    }
}

# ---------------- 8. Routes / VPN ----------------
try {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric)
    $rt = ($routes | ForEach-Object { "$($_.InterfaceAlias)->$($_.NextHop) (m$($_.RouteMetric))" }) -join '; '
    $vpnLike = @($routes | Where-Object { $_.InterfaceAlias -match 'VPN|PPP|WAN Miniport|Tunnel|GlobalProtect|AnyConnect|Fortinet|Zscaler|wg' })
    if ($routes.Count -eq 0) {
        Add-Result 'Routing' 'Default route' 'ERROR' 'None' 'No default route -> NoRoute verdict (NCSI-B Fix 6 if VPN involved).'
        $fixPaths.Add('Fix 6')
    } elseif ($vpnLike.Count -gt 0) {
        Add-Result 'Routing' 'Default route' 'WARN' $rt 'VPN-style interface holds a default route - judge the VPN interface verdict, physical NIC Local is expected under forced tunnel (NCSI-B Fix 6).'
        if (-not $anyInternet) { $fixPaths.Add('Fix 6') }
    } else {
        Add-Result 'Routing' 'Default route' 'OK' $rt
    }
} catch {
    Add-Result 'Routing' 'Default route' 'WARN' "Could not read routes: $($_.Exception.Message)"
}

# ---------------- 9. Events ----------------
try {
    $events = @(Get-WinEvent -LogName 'Microsoft-Windows-NCSI/Operational' -MaxEvents $EventCount -ErrorAction Stop)
    $reasons = @($events | ForEach-Object {
        if ($_.Message -match 'ChangeReason:\s*([A-Za-z]+)') { $Matches[1] }
    } | Where-Object { $_ })
    if ($reasons.Count -gt 0) {
        $grouped = ($reasons | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ', '
        $latest = $reasons[0]
        $st = if ($latest -match 'Failed|NoRoute|NoAddress|NoGlobalAddress|Hotspot') { 'WARN' } else { 'OK' }
        Add-Result 'Events' 'ChangeReason (latest first)' $st "Latest=$latest; Seen: $grouped"
        if ($latest -match 'Hotspot') { $fixPaths.Add('Fix 3') }
        if ($latest -match 'NoRoute') { $fixPaths.Add('Fix 6') }
    } else {
        Add-Result 'Events' 'ChangeReason' 'INFO' "$($events.Count) events read, no ChangeReason entries"
    }
    Add-Result 'Events' 'Last event' 'INFO' $(if ($events.Count) { "$($events[0].TimeCreated) Id=$($events[0].Id)" } else { 'none' })
} catch {
    Add-Result 'Events' 'NCSI/Operational' 'WARN' "Unreadable: $($_.Exception.Message)" 'Run elevated.'
}

# ---------------- Verdict / report ----------------
if ($anyInternet -and $fixPaths.Count -eq 0) {
    Add-Result 'Summary' 'Overall' 'OK' 'NCSI reports Internet and no probe issues found' 'If an app still claims offline, it is the app''s own check - use the app runbook.'
} elseif (-not $anyInternet -and $httpOk -and $dnsOk -and $fixPaths.Count -eq 0) {
    Add-Result 'Summary' 'Overall' 'WARN' 'Probe dependencies pass now but verdict is stale' 'Force a re-probe: Restart-NetAdapter (NCSI-B Fix 1).'
} else {
    $uniq = @($fixPaths | Select-Object -Unique) -join ', '
    Add-Result 'Summary' 'Overall' $(if ($anyInternet) { 'WARN' } else { 'ERROR' }) "Recommended: $uniq" 'See Windows/Troubleshooting/NCSI-B.md'
}

$csv = Join-Path $OutputPath ("NCSI-Diagnostics-{0}-{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Report written: $csv" "OK"
