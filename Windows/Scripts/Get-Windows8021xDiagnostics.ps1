<#
.SYNOPSIS
    Read-only diagnostics for Windows 802.1X (enterprise Wi-Fi and wired) supplicant health.

.DESCRIPTION
    Collects and evaluates the client-side prerequisites for 802.1X authentication on Windows 10/11:
      - WLAN AutoConfig (WlanSvc) and Wired AutoConfig (dot3svc) service state
      - Wi-Fi profiles (source: user / group policy / MDM) and their exported EAP settings
        (EAP type, auth mode, server names, trusted root thumbprints) - verifies each root is
        present in LocalMachine\Root
      - Machine (and optionally current-user) client-authentication certificates, expiry, private
        key, and presence of a strong-mapping SID (NTDS_CA_SECURITY_EXT or Intune SAN SID tag)
      - Device join state (hybrid vs cloud-only) - cloud-only + machine EAP-TLS against AD-backed NPS is flagged
      - Credential Guard running state - flagged when PEAP profiles exist
      - Recent WLAN / Wired AutoConfig Operational events (802.1X start/success/failure)
    Outputs a findings table and exports findings + certificates + events to CSV.

    Does NOT: change any setting, delete profiles, contact the RADIUS server, or read NPS logs
    (run NPS-side checks from NPS-RADIUS-B.md on the server).

.PARAMETER SSID
    Optional. Limit profile analysis to this SSID.

.PARAMETER Hours
    How far back to read AutoConfig events. Default 24.

.PARAMETER IncludeUserCerts
    Also evaluate client-auth certs in CurrentUser\My (run in the user's context for meaningful results).

.PARAMETER GenerateWlanReport
    Runs 'netsh wlan show wlanreport' and copies the HTML into the output folder.

.PARAMETER OutputPath
    Folder for CSV/report output. Default C:\Temp\8021xDiag.

.EXAMPLE
    .\Get-Windows8021xDiagnostics.ps1 -SSID 'CORP-WIFI' -GenerateWlanReport

.EXAMPLE
    .\Get-Windows8021xDiagnostics.ps1 -Hours 72 -IncludeUserCerts -OutputPath D:\Evidence

.NOTES
    Requires: Windows 10 22H2 / Windows 11, Windows PowerShell 5.1+.
    Run as: Administrator recommended (event logs, profile export, machine store private-key check).
    Safe: read-only. Profile XML exported by netsh contains no secrets for EAP profiles
    (key material is not exported without key=clear, which this script does not use).
    Companion to Windows/Troubleshooting/WiFi-8021x-Windows-A.md / -B.md.
#>
[CmdletBinding()]
param(
    [string]$SSID,
    [ValidateRange(1, 720)][int]$Hours = 24,
    [switch]$IncludeUserCerts,
    [switch]$GenerateWlanReport,
    [string]$OutputPath = 'C:\Temp\8021xDiag'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Area, [string]$Item, [string]$Status, [string]$Detail)
    $findings.Add([pscustomobject]@{ Area = $Area; Item = $Item; Status = $Status; Detail = $Detail })
    Write-Status "$Area | $Item - $Detail" $Status
}

# ---------------- Preflight ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Status 'Not elevated - event log and some certificate checks may be incomplete.' 'WARN' }

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $OutputPath "$env:COMPUTERNAME-$stamp"
New-Item -Path $runDir -ItemType Directory -Force | Out-Null
$profDir = Join-Path $runDir 'profiles'
New-Item -Path $profDir -ItemType Directory -Force | Out-Null

$clientAuthOid = '1.3.6.1.5.5.7.3.2'
$sidExtOid     = '1.3.6.1.4.1.311.25.2'
$sanOid        = '2.5.29.17'

# ---------------- Detect: services ----------------
foreach ($svcName in 'WlanSvc', 'dot3svc') {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { Add-Finding 'Service' $svcName 'WARN' 'Not present on this system'; continue }
    $start = (Get-CimInstance Win32_Service -Filter "Name='$svcName'").StartMode
    if ($svc.Status -eq 'Running') {
        Add-Finding 'Service' $svcName 'OK' "Running (StartMode $start)"
    }
    elseif ($svcName -eq 'dot3svc') {
        Add-Finding 'Service' $svcName 'WARN' "$($svc.Status) (StartMode $start) - wired 802.1X will not start until set Automatic and started"
    }
    else {
        Add-Finding 'Service' $svcName 'ERROR' "$($svc.Status) (StartMode $start) - Wi-Fi 802.1X impossible"
    }
}

# ---------------- Detect: join state ----------------
$joinType = 'Unknown'
try {
    $dsreg = (& dsregcmd.exe /status) -join "`n"
    $aad   = $dsreg -match 'AzureAdJoined\s*:\s*YES'
    $dom   = $dsreg -match 'DomainJoined\s*:\s*YES'
    $joinType = if ($aad -and $dom) { 'HybridJoined' } elseif ($aad) { 'EntraJoinedCloudOnly' } elseif ($dom) { 'DomainJoinedOnly' } else { 'Workgroup/Registered' }
    Add-Finding 'Identity' 'Join state' 'INFO' $joinType
}
catch { Add-Finding 'Identity' 'Join state' 'WARN' "dsregcmd failed: $($_.Exception.Message)" }

# ---------------- Detect: Credential Guard ----------------
$cgRunning = $false
try {
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    $running = @($dg.SecurityServicesRunning)
    $cgRunning = $running -contains 1
    Add-Finding 'Identity' 'Credential Guard' 'INFO' ($(if ($cgRunning) { 'Running' } else { 'Not running' }))
}
catch { Add-Finding 'Identity' 'Credential Guard' 'WARN' 'Could not query Win32_DeviceGuard' }

# ---------------- Detect: Wi-Fi driver capability ----------------
try {
    $drv = (& netsh.exe wlan show drivers) -join "`n"
    if ($drv -match 'There is no wireless interface|wireless autoconfig service.*not running') {
        Add-Finding 'Wi-Fi' 'Driver' 'INFO' 'No wireless interface / service not running'
    }
    else {
        $ent = @()
        if ($drv -match 'WPA2-Enterprise') { $ent += 'WPA2-Enterprise' }
        if ($drv -match 'WPA3-Enterprise') { $ent += 'WPA3-Enterprise' }
        $st = if ($ent.Count -gt 0) { 'OK' } else { 'WARN' }
        Add-Finding 'Wi-Fi' 'Driver enterprise auth' $st ($(if ($ent.Count) { $ent -join ', ' } else { 'No Enterprise auth listed by driver' }))
    }
}
catch { Add-Finding 'Wi-Fi' 'Driver' 'WARN' "netsh failed: $($_.Exception.Message)" }

# ---------------- Detect: profiles ----------------
$profileRows = New-Object System.Collections.Generic.List[object]
$hasPeap = $false
$hasMachineTls = $false
try {
    $exportArgs = @('wlan', 'export', 'profile', "folder=$profDir")
    if ($SSID) { $exportArgs = @('wlan', 'export', 'profile', "name=$SSID", "folder=$profDir") }
    & netsh.exe @exportArgs | Out-Null
    $xmlFiles = @(Get-ChildItem -Path $profDir -Filter *.xml -ErrorAction SilentlyContinue)
    if ($xmlFiles.Count -eq 0) { Add-Finding 'Wi-Fi' 'Profiles' 'WARN' ($(if ($SSID) { "No profile named '$SSID'" } else { 'No Wi-Fi profiles exported' })) }

    $rootThumbs = @(Get-ChildItem Cert:\LocalMachine\Root | ForEach-Object { $_.Thumbprint.ToUpperInvariant() })

    foreach ($f in $xmlFiles) {
        $raw  = Get-Content -Path $f.FullName -Raw
        $name = if ($raw -match '<name>([^<]+)</name>') { $Matches[1] } else { $f.BaseName }
        $auth = if ($raw -match '<authentication>([^<]+)</authentication>') { $Matches[1] } else { '' }
        if ($auth -notmatch 'WPA2$|WPA3ENT|WPA3$|WPA$') {
            # Personal/open profiles are not 802.1X - record and skip
            $profileRows.Add([pscustomobject]@{ Profile = $name; Auth = $auth; EapType = ''; AuthMode = ''; ServerNames = ''; TrustedRoots = ''; RootsMissing = ''; Is8021X = $false })
            continue
        }
        $eapType  = if ($raw -match '<Type[^>]*>(\d+)</Type>') { $Matches[1] } else { '' }
        $authMode = if ($raw -match '<authMode>([^<]+)</authMode>') { $Matches[1] } else { 'machineOrUser(default)' }
        $servers  = if ($raw -match '<ServerNames>([^<]*)</ServerNames>') { $Matches[1] } else { '' }
        $roots    = @([regex]::Matches($raw, '<TrustedRootCA>([^<]+)</TrustedRootCA>') | ForEach-Object { ($_.Groups[1].Value -replace '\s', '').ToUpperInvariant() })
        $missing  = @($roots | Where-Object { $rootThumbs -notcontains $_ })

        $profileRows.Add([pscustomobject]@{
            Profile = $name; Auth = $auth; EapType = $eapType; AuthMode = $authMode; ServerNames = $servers
            TrustedRoots = ($roots -join ';'); RootsMissing = ($missing -join ';'); Is8021X = $true })

        $eapLabel = switch ($eapType) { '13' { 'EAP-TLS' } '25' { 'PEAP' } '21' { 'EAP-TTLS' } default { "Type $eapType" } }
        if ($eapType -eq '25') { $hasPeap = $true }
        if ($eapType -eq '13' -and $authMode -match 'machine') { $hasMachineTls = $true }

        Add-Finding 'Profile' $name 'INFO' "$auth / $eapLabel / authMode=$authMode"
        if (-not $servers) { Add-Finding 'Profile' $name 'WARN' 'No ServerNames - server identity not pinned (evil-twin risk, and validation may prompt/fail)' }
        if ($roots.Count -eq 0) { Add-Finding 'Profile' $name 'WARN' 'No TrustedRootCA thumbprints in profile' }
        elseif ($missing.Count -gt 0) { Add-Finding 'Profile' $name 'ERROR' "Trusted root(s) not in LocalMachine\Root: $($missing -join ', ') - Trusted certificate profile not applied" }
        else { Add-Finding 'Profile' $name 'OK' "All $($roots.Count) trusted root(s) present locally" }
    }
}
catch { Add-Finding 'Wi-Fi' 'Profiles' 'WARN' "Profile export/parse failed: $($_.Exception.Message)" }

# Wired profiles (presence only)
try {
    $lan = (& netsh.exe lan show profiles) -join "`n"
    if ($lan -match 'service.*not running') { Add-Finding 'Wired' 'Profiles' 'INFO' 'Wired AutoConfig not running - no wired profiles evaluated' }
    elseif ($lan -match '802\.1X\s*:\s*Enabled') { Add-Finding 'Wired' 'Profiles' 'INFO' 'At least one wired profile has 802.1X enabled' }
    else { Add-Finding 'Wired' 'Profiles' 'INFO' 'No wired 802.1X profile detected' }
}
catch { Add-Finding 'Wired' 'Profiles' 'INFO' 'netsh lan unavailable' }

# ---------------- Detect: certificates ----------------
function Get-ClientAuthCerts {
    param([string]$StorePath, [string]$Context)
    $now = Get-Date
    foreach ($c in @(Get-ChildItem -Path $StorePath -ErrorAction SilentlyContinue)) {
        $ekus = @()
        try { $ekus = @($c.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }) } catch { $ekus = @() }
        if ($ekus -notcontains $clientAuthOid) { continue }
        $sidExt = [bool]($c.Extensions | Where-Object { $_.Oid.Value -eq $sidExtOid })
        $sanExt = $c.Extensions | Where-Object { $_.Oid.Value -eq $sanOid } | Select-Object -First 1
        $sanTxt = if ($sanExt) { $sanExt.Format($false) } else { '' }
        $sidTag = $sanTxt -match 'tag:microsoft\.com,2022-09-14:sid:'
        [pscustomobject]@{
            Context       = $Context
            Subject       = $c.Subject
            Issuer        = $c.Issuer
            NotAfter      = $c.NotAfter
            DaysLeft      = [int]($c.NotAfter - $now).TotalDays
            HasPrivateKey = $c.HasPrivateKey
            SidExtension  = $sidExt
            SanSidTag     = $sidTag
            SAN           = $sanTxt
            Thumbprint    = $c.Thumbprint
        }
    }
}
$certs = @(Get-ClientAuthCerts -StorePath 'Cert:\LocalMachine\My' -Context 'Machine')
if ($IncludeUserCerts) { $certs += @(Get-ClientAuthCerts -StorePath 'Cert:\CurrentUser\My' -Context 'User') }

$machineCerts = @($certs | Where-Object Context -eq 'Machine')
if ($machineCerts.Count -eq 0) {
    $st = if ($hasMachineTls) { 'ERROR' } else { 'INFO' }
    Add-Finding 'Certificate' 'Machine client-auth' $st 'No client-auth certificate in LocalMachine\My'
}
foreach ($c in $certs) {
    $label = "$($c.Context): $($c.Subject)"
    if (-not $c.HasPrivateKey) { Add-Finding 'Certificate' $label 'ERROR' 'No private key - unusable for EAP-TLS' }
    if ($c.DaysLeft -lt 0) { Add-Finding 'Certificate' $label 'ERROR' "Expired $($c.NotAfter)" }
    elseif ($c.DaysLeft -lt 30) { Add-Finding 'Certificate' $label 'WARN' "Expires in $($c.DaysLeft) days" }
    if (-not ($c.SidExtension -or $c.SanSidTag)) {
        Add-Finding 'Certificate' $label 'WARN' 'No SID extension or SAN SID tag - weak mapping; NPS (AD) may reject under strong-mapping enforcement unless altSecurityIdentities is set'
    }
    else { Add-Finding 'Certificate' $label 'OK' "Strong-mapping SID present (Ext=$($c.SidExtension) Tag=$($c.SanSidTag)), $($c.DaysLeft) days left" }
}

# ---------------- Evaluate: identity model conflicts ----------------
if ($hasPeap -and $cgRunning) {
    Add-Finding 'Design' 'PEAP + Credential Guard' 'WARN' 'PEAP profile present and Credential Guard running - MS-CHAPv2 SSO/saved creds are blocked; migrate to EAP-TLS'
}
if ($hasMachineTls -and $joinType -eq 'EntraJoinedCloudOnly') {
    Add-Finding 'Design' 'Cloud-only + machine EAP-TLS' 'WARN' 'No AD computer object - AD-backed NPS cannot map a device cert without shadow objects/altSecurityIdentities or a cloud RADIUS'
}

# ---------------- Detect: events ----------------
$since = (Get-Date).AddHours(-$Hours)
$eventRows = New-Object System.Collections.Generic.List[object]
foreach ($log in 'Microsoft-Windows-WLAN-AutoConfig/Operational', 'Microsoft-Windows-Wired-AutoConfig/Operational') {
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -ErrorAction Stop)
        foreach ($e in $evts) {
            $firstLines = (($e.Message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 8) -join ' | '
            $eventRows.Add([pscustomobject]@{ Log = $log; Time = $e.TimeCreated; Id = $e.Id; Level = $e.LevelDisplayName; Message = $firstLines })
        }
    }
    catch {
        if ($_.Exception.Message -notmatch 'No events were found') { Write-Status "Could not read ${log}: $($_.Exception.Message)" 'WARN' }
    }
}
$wlanFail = @($eventRows | Where-Object { $_.Log -like '*WLAN*' -and $_.Id -in 12013, 8002 })
$wlanOk   = @($eventRows | Where-Object { $_.Log -like '*WLAN*' -and $_.Id -eq 12012 })
if ($wlanFail.Count -gt 0) {
    $last = $wlanFail | Sort-Object Time -Descending | Select-Object -First 1
    Add-Finding 'Events' 'WLAN failures' 'WARN' "$($wlanFail.Count) failure event(s) in ${Hours}h; latest $($last.Time) (Id $($last.Id)): $($last.Message)"
}
Add-Finding 'Events' 'WLAN 802.1X successes' 'INFO' "$($wlanOk.Count) event 12012 in ${Hours}h"

# ---------------- Optional: WLAN report ----------------
if ($GenerateWlanReport) {
    try {
        & netsh.exe wlan show wlanreport | Out-Null
        $rep = Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html'
        if (Test-Path $rep) { Copy-Item $rep $runDir; Add-Finding 'Report' 'wlanreport' 'OK' 'Copied wlan-report-latest.html' }
        else { Add-Finding 'Report' 'wlanreport' 'WARN' 'Report not generated (needs elevation / WLAN service)' }
    }
    catch { Add-Finding 'Report' 'wlanreport' 'WARN' $_.Exception.Message }
}

# ---------------- Report ----------------
$findings   | Export-Csv (Join-Path $runDir 'findings.csv') -NoTypeInformation
$profileRows| Export-Csv (Join-Path $runDir 'profiles.csv') -NoTypeInformation
$certs      | Export-Csv (Join-Path $runDir 'client-auth-certs.csv') -NoTypeInformation
$eventRows  | Export-Csv (Join-Path $runDir 'autoconfig-events.csv') -NoTypeInformation

$errs  = @($findings | Where-Object Status -eq 'ERROR').Count
$warns = @($findings | Where-Object Status -eq 'WARN').Count
Write-Host ''
$verdict = if ($errs) { 'ERROR' } elseif ($warns) { 'WARN' } else { 'OK' }
Write-Status "Summary: $errs error(s), $warns warning(s). Output: $runDir" $verdict
Write-Status 'Next: compare with NPS Security event 6273 Reason Code on the RADIUS server (NPS-RADIUS-B.md).' 'INFO'
