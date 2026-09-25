<#
.SYNOPSIS
    Checks whether a Windows device (and the current user) can receive Microsoft 365
    Organizational messages on the Windows 11 channels (Spotlight, Taskbar, Notification Center).

.DESCRIPTION
    Organizational messages are authored in the Microsoft 365 admin center but only render
    on Windows when a chain of device and user conditions is met. See
    M365/OrganizationalMessages/OrganizationalMessages-A.md / -B.md.

    Checks performed (Preflight -> Detect -> Validate -> Report):
      - OS edition (Experience CSPs are Enterprise/Education/IoT Enterprise only; Pro unsupported)
      - OS build (product page baseline: Windows 11 24H2 [26100] / 25H2 [26200])
      - Join state (Entra joined or Entra hybrid joined) via dsregcmd
      - MDM-delivered Experience CSP values under HKLM:\SOFTWARE\Microsoft\PolicyManager\current\*\Experience
          EnableOrganizationalMessages (must be 1; default 0; MDM-only)
          AllowWindowsSpotlight (0 blocks all child Spotlight/Tips policies)
          AllowWindowsSpotlightOnActionCenter, ConfigureWindowsSpotlightOnLockScreen,
          AllowWindowsTips, DisableCloudOptimizedContent
      - GPO blockers under Software\Policies\Microsoft\Windows\CloudContent (HKCU + HKLM)
      - HTTPS reachability of fd.api.orgmsg.microsoft.com and ris.prod.api.personalization.ideas.microsoft.com
      - KB5094126 presence (Taskbar channel) - informational, since later cumulative updates supersede it
      - First Windows display language (custom messages only reach matching locales)

    It does NOT check tenant-side state (message status, approvals, targeting, licensing).
    No Graph connection needed. Read-only.

.PARAMETER SkipNetworkTest
    Skip the TCP 443 endpoint tests (for example on a disconnected lab machine).

.PARAMETER ExportPath
    CSV path. Defaults to $env:TEMP\OrgMessagesDeviceReadiness-<computer>-<timestamp>.csv.

.EXAMPLE
    .\Get-OrgMessagesDeviceReadiness.ps1
    Run in the affected user's (non-elevated) session to see user-scoped policy and GPO values.

.EXAMPLE
    .\Get-OrgMessagesDeviceReadiness.ps1 -SkipNetworkTest -ExportPath C:\Temp\orgmsg.csv

.NOTES
    Run as the USER who should receive messages (HKCU policy values and user-scoped MDM keys matter).
    Elevation is not required. Windows PowerShell 5.1 or PowerShell 7. Safe: read-only.
#>
[CmdletBinding()]
param(
    [switch]$SkipNetworkTest,
    [string]$ExportPath = "$env:TEMP\OrgMessagesDeviceReadiness-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Check, [string]$Status, [string]$Value, [string]$Detail)
    $results.Add([pscustomobject]@{ Computer = $env:COMPUTERNAME; User = $env:USERNAME; Check = $Check; Status = $Status; Value = $Value; Detail = $Detail })
    Write-Status "$Check : $Value - $Detail" $Status
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if ($item.PSObject.Properties[$Name]) { return $item.$Name }
    return $null
}

# ---------------- Preflight ----------------
if ($env:OS -ne 'Windows_NT') { Write-Status "Windows only." "ERROR"; return }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Write-Status "Running elevated. HKCU values reflect THIS account - run in the target user's session if different." "WARN" }

# ---------------- OS ----------------
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$edition = [string]$cv.EditionID
$build = [int]$cv.CurrentBuild
$ubr = if ($cv.PSObject.Properties['UBR']) { [int]$cv.UBR } else { 0 }
$display = if ($cv.PSObject.Properties['DisplayVersion']) { [string]$cv.DisplayVersion } else { '' }

if ($edition -match '^(Enterprise|Education|IoTEnterprise)') { Add-Result 'Edition' 'OK' $edition 'Supported edition for Experience CSPs' }
elseif ($edition -match 'Professional|Core') { Add-Result 'Edition' 'ERROR' $edition 'Pro/Home not supported by the Experience CSPs - Enterprise upgrade (subscription activation) required for Windows channels' }
else { Add-Result 'Edition' 'WARN' $edition 'Unrecognised edition - verify manually' }

if ($build -ge 26100) { Add-Result 'OS build' 'OK' "$build.$ubr ($display)" 'Meets Windows 11 24H2/25H2 baseline' }
else { Add-Result 'OS build' 'ERROR' "$build.$ubr ($display)" 'Below Windows 11 24H2 (26100) - product page baseline for Windows channels' }

# ---------------- Join state ----------------
$aadJoined = 'UNKNOWN'; $domainJoined = 'UNKNOWN'
try {
    $ds = & "$env:SystemRoot\System32\dsregcmd.exe" /status 2>$null
    foreach ($line in $ds) {
        if ($line -match '^\s*AzureAdJoined\s*:\s*(\w+)') { $aadJoined = $Matches[1] }
        if ($line -match '^\s*DomainJoined\s*:\s*(\w+)') { $domainJoined = $Matches[1] }
    }
} catch { Write-Status "dsregcmd failed: $($_.Exception.Message)" "WARN" }
if ($aadJoined -eq 'YES') {
    $jt = if ($domainJoined -eq 'YES') { 'Entra hybrid joined' } else { 'Entra joined' }
    Add-Result 'Join state' 'OK' $jt 'Supported'
} else {
    Add-Result 'Join state' 'ERROR' "AzureAdJoined=$aadJoined DomainJoined=$domainJoined" 'Only Entra joined / Entra hybrid joined devices are supported'
}

# ---------------- MDM Experience CSP values ----------------
$pmRoot = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current'
$cspNames = @('EnableOrganizationalMessages', 'AllowWindowsSpotlight', 'AllowWindowsSpotlightOnActionCenter', 'ConfigureWindowsSpotlightOnLockScreen', 'AllowWindowsTips', 'DisableCloudOptimizedContent')
$found = @{}
foreach ($n in $cspNames) { $found[$n] = New-Object System.Collections.Generic.List[string] }
if (Test-Path $pmRoot) {
    foreach ($scopeKey in (Get-ChildItem -LiteralPath $pmRoot -ErrorAction SilentlyContinue)) {
        $exp = Join-Path $scopeKey.PSPath 'Experience'
        foreach ($n in $cspNames) {
            $v = Get-RegValue -Path $exp -Name $n
            if ($null -ne $v) { $found[$n].Add("$($scopeKey.PSChildName)=$v") }
        }
    }
}
function Get-Vals { param([string]$Name) return @($found[$Name] | ForEach-Object { [int]($_.Split('=')[-1]) }) }

$eom = Get-Vals 'EnableOrganizationalMessages'
if ($eom -contains 1) { Add-Result 'EnableOrganizationalMessages' 'OK' ($found['EnableOrganizationalMessages'] -join '; ') 'Delivery enabled by MDM' }
elseif ($eom.Count -gt 0) { Add-Result 'EnableOrganizationalMessages' 'ERROR' ($found['EnableOrganizationalMessages'] -join '; ') 'Set to 0 - set Enable delivery of organizational messages (User) = Allow' }
else { Add-Result 'EnableOrganizationalMessages' 'ERROR' 'not set' 'Default is 0 (disabled) and there is no GPO equivalent - deploy via Intune Settings catalog (user-assigned)' }

$aws = Get-Vals 'AllowWindowsSpotlight'
if ($aws -contains 0) { Add-Result 'AllowWindowsSpotlight' 'ERROR' ($found['AllowWindowsSpotlight'] -join '; ') 'Master switch OFF - blocks Tips/ActionCenter/LockScreen child policies' }
else { Add-Result 'AllowWindowsSpotlight' 'OK' $(if ($aws.Count) { $found['AllowWindowsSpotlight'] -join '; ' } else { 'not set (default 1)' }) 'Not blocked by MDM' }

foreach ($n in @('AllowWindowsSpotlightOnActionCenter', 'AllowWindowsTips')) {
    $vals = Get-Vals $n
    if ($vals -contains 0) { Add-Result $n 'WARN' ($found[$n] -join '; ') 'Blocked by MDM - channel may not render' }
    else { Add-Result $n 'OK' $(if ($vals.Count) { $found[$n] -join '; ' } else { 'not set (default 1)' }) 'Not blocked by MDM' }
}
$lock = Get-Vals 'ConfigureWindowsSpotlightOnLockScreen'
if ($lock -contains 0) { Add-Result 'ConfigureWindowsSpotlightOnLockScreen' 'WARN' ($found['ConfigureWindowsSpotlightOnLockScreen'] -join '; ') 'Spotlight lock screen disabled - Spotlight channel will not render' }
else { Add-Result 'ConfigureWindowsSpotlightOnLockScreen' 'OK' $(if ($lock.Count) { $found['ConfigureWindowsSpotlightOnLockScreen'] -join '; ' } else { 'not set (default 1)' }) 'Not blocked by MDM' }

$dcoc = Get-Vals 'DisableCloudOptimizedContent'
if ($dcoc -contains 1) { Add-Result 'DisableCloudOptimizedContent' 'ERROR' ($found['DisableCloudOptimizedContent'] -join '; ') 'Cloud optimized content disabled by MDM - set to Disabled' }
else { Add-Result 'DisableCloudOptimizedContent' 'OK' $(if ($dcoc.Count) { $found['DisableCloudOptimizedContent'] -join '; ' } else { 'not set (default 0)' }) 'Not blocked by MDM' }

# ---------------- GPO blockers (CloudContent) ----------------
$gpoChecks = @(
    @{ Hive = 'HKCU'; Name = 'DisableWindowsSpotlightFeatures'; Bad = 1; Detail = 'GPO: Turn off all Windows spotlight features' },
    @{ Hive = 'HKCU'; Name = 'DisableWindowsSpotlightOnActionCenter'; Bad = 1; Detail = 'GPO: Turn off Windows Spotlight on Action Center' },
    @{ Hive = 'HKLM'; Name = 'DisableSoftLanding'; Bad = 1; Detail = 'GPO: Do not show Windows tips' },
    @{ Hive = 'HKLM'; Name = 'DisableCloudOptimizedContent'; Bad = 1; Detail = 'GPO: Turn off cloud optimized content' }
)
$gpoHit = $false
foreach ($g in $gpoChecks) {
    $v = Get-RegValue -Path "$($g.Hive):\Software\Policies\Microsoft\Windows\CloudContent" -Name $g.Name
    if ($null -ne $v -and [int]$v -eq $g.Bad) { Add-Result "GPO $($g.Name)" 'ERROR' "$($g.Hive)=$v" $g.Detail; $gpoHit = $true }
}
$cws = Get-RegValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' -Name 'ConfigureWindowsSpotlight'
if ($null -ne $cws) { Add-Result 'GPO ConfigureWindowsSpotlight' 'INFO' "HKCU=$cws" 'Lock-screen Spotlight configured by GPO - confirm the value does not disable Spotlight' ; $gpoHit = $true }
if (-not $gpoHit) { Add-Result 'GPO CloudContent' 'OK' 'none' 'No blocking CloudContent GPO values found' }

# ---------------- Network ----------------
if (-not $SkipNetworkTest) {
    foreach ($h in @('fd.api.orgmsg.microsoft.com', 'ris.prod.api.personalization.ideas.microsoft.com')) {
        $ok = $false
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($h, 443, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(5000, $false) -and $client.Connected) { $ok = $true }
            $client.Close()
        } catch { $ok = $false }
        if ($ok) { Add-Result "Endpoint $h" 'OK' 'TCP 443 reachable' 'Direct TCP test (proxy-only networks may show false negatives)' }
        else { Add-Result "Endpoint $h" 'WARN' 'TCP 443 NOT reachable' 'Allow-list on firewall/proxy; if a proxy is mandatory, verify with a browser or Invoke-WebRequest via proxy' }
    }
} else { Add-Result 'Endpoints' 'INFO' 'skipped' '-SkipNetworkTest' }

# ---------------- Taskbar KB ----------------
$kb = $null
try { $kb = Get-HotFix -Id 'KB5094126' -ErrorAction SilentlyContinue } catch { $kb = $null }
if ($kb) { Add-Result 'KB5094126 (Taskbar)' 'OK' 'installed' 'Taskbar channel prerequisite present' }
else { Add-Result 'KB5094126 (Taskbar)' 'INFO' "not listed (build $build.$ubr)" 'May be superseded by a later cumulative update - compare build/UBR with the KB article before concluding it is missing' }

# ---------------- Locale ----------------
try {
    $lang = (Get-WinUserLanguageList)[0].LanguageTag
    $supported = @('en-US','de-DE','es-ES','fr-FR','it-IT','ja-JP','ko-KR','nl-NL','pl-PL','pt-BR','pt-PT','ru-RU','tr-TR','zh-Hans','zh-Hant')
    $base = $lang.Split('-')[0]
    if ($supported -contains $lang) { Add-Result 'Display language' 'OK' $lang 'Supported locale (custom messages must be authored in this language)' }
    elseif (@($supported | Where-Object { $_.Split('-')[0] -eq $base }).Count -gt 0) { Add-Result 'Display language' 'INFO' $lang 'Not exact, same-language fallback likely (e.g. fr-CA -> fr-FR)' }
    else { Add-Result 'Display language' 'WARN' $lang 'No supported locale mapping - user will not receive messages' }
} catch { Add-Result 'Display language' 'INFO' 'unknown' "Get-WinUserLanguageList failed: $($_.Exception.Message)" }

# ---------------- Report ----------------
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
$err = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Host ""
if ($err -gt 0) { Write-Status "$err blocking issue(s), $warn warning(s): Windows-channel organizational messages will not render on this device/user." "ERROR" }
elseif ($warn -gt 0) { Write-Status "No blockers; $warn warning(s) - some channels may not render." "WARN" }
else { Write-Status "Device/user ready. If messages still don't appear, check message state and allow 24h+ (pull-based delivery)." "OK" }
Write-Status "Report: $ExportPath" "INFO"
