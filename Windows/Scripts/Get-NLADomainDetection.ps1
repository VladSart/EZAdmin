<#
.SYNOPSIS
    Diagnoses why a domain-joined Windows host is not getting the DomainAuthenticated network category (Public/Private firewall profile on the domain LAN).

.DESCRIPTION
    Collects and interprets everything that decides NLA domain network detection:
      - Join state and role (member / DC) from Win32_ComputerSystem
      - OS build + UBR, with a Server 2025 DC check against the KB5060842 fix (26100.4349)
      - NlaSvc / netprofm / Netlogon service state and start type (incl. delayed start)
      - NlaSvc\Parameters AlwaysExpectDomainController workaround flag
      - Per-interface network category, IPv4 connectivity and DNS servers
      - Active firewall profile(s)
      - DC locator (nltest /dsgetdc /force), SRV record resolution, TCP 389 to the located DC
      - DC-only: DNS client ordering (self-only / loopback-first resolver lists)
      - Recent NetworkProfile/Operational 10000 events (category assigned at connect)
    Produces OK / WARN / ERROR findings mapped to NLADomainProfile-B.md fix numbers and exports a CSV.

    Read-only by default. With -Remediate it performs ONLY the non-destructive Fix 1 path:
    nltest /dsgetdc /force + Restart-Service NlaSvc, then re-reads categories. It never changes
    registry, service start types, DNS servers or adapters.

    Not covered: NCSI internet verdicts (use Get-NCSIDiagnostics.ps1), firewall rule analysis
    (use Get-FirewallDiagnostics.ps1). UDP 389 reachability cannot be proven from PowerShell alone;
    nltest success is used as the proxy for the CLDAP ping.

.PARAMETER OutputPath
    Folder for the CSV report. Defaults to $env:TEMP.

.PARAMETER Remediate
    Run Fix 1 (clear DC-locator negative cache + restart NlaSvc) and re-check. Briefly re-identifies
    networks; the firewall profile may change during the restart.

.PARAMETER EventCount
    Number of recent NetworkProfile/Operational events to inspect. Default 30.

.EXAMPLE
    .\Get-NLADomainDetection.ps1
    Read-only diagnosis, CSV written to %TEMP%.

.EXAMPLE
    .\Get-NLADomainDetection.ps1 -Remediate -OutputPath C:\Temp
    Diagnose, force re-detection, re-check, CSV to C:\Temp.

.NOTES
    Requires: Windows PowerShell 5.1+, NetTCPIP / NetConnection / NetSecurity / DnsClient modules (in-box).
    Run as: Administrator (service restart and firewall ActiveStore read).
    Safe: read-only unless -Remediate. -Remediate restarts NlaSvc only.
    Related runbooks: Windows/Troubleshooting/NLADomainProfile-B.md, NLADomainProfile-A.md
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputPath = $env:TEMP,
    [switch]$Remediate,
    [ValidateRange(1, 500)]
    [int]$EventCount = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Area, [string]$Status, [string]$Detail, [string]$Fix = "")
    $Findings.Add([pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Area     = $Area
        Status   = $Status
        Detail   = $Detail
        FixRef   = $Fix
    })
    Write-Status -Message ("{0}: {1}" -f $Area, $Detail) -Status $Status
}

function Get-InterfaceCategories {
    @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias, InterfaceIndex, Name, NetworkCategory, IPv4Connectivity)
}

# ---------------- Preflight ----------------
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
$ubr = 0
if ($cv.PSObject.Properties.Name -contains 'UBR') { $ubr = [int]$cv.UBR }
$isDC = ($cs.DomainRole -ge 4)
$domain = [string]$cs.Domain

Write-Status "Host $($env:COMPUTERNAME) | $($cv.ProductName) | build $build.$ubr | DomainRole $($cs.DomainRole)"

if (-not $cs.PartOfDomain) {
    Add-Finding -Area "JoinState" -Status "ERROR" -Detail "Not domain-joined (workgroup/Entra-only). DomainAuthenticated is impossible; classify as Private via policy." -Fix "Fix 5"
} else {
    Add-Finding -Area "JoinState" -Status "OK" -Detail "Domain-joined to $domain$(if ($isDC) { ' (domain controller)' })"
}

# ---------------- Detect: OS defect ----------------
if ($isDC -and $build -eq 26100 -and $cv.ProductName -match 'Server') {
    if ($ubr -lt 4349) {
        Add-Finding -Area "OSBuild" -Status "ERROR" -Detail "Server 2025 DC at 26100.$ubr - below KB5060842 (26100.4349) fix for non-domain profile after restart" -Fix "Fix 3"
    } else {
        Add-Finding -Area "OSBuild" -Status "OK" -Detail "Server 2025 DC at 26100.$ubr (includes KB5060842 fix)"
    }
}

# ---------------- Detect: services ----------------
foreach ($svcName in @('NlaSvc', 'netprofm', 'Netlogon')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Add-Finding -Area "Service:$svcName" -Status "WARN" -Detail "Service not present"
        continue
    }
    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
    $delayed = $false
    $sk = Get-ItemProperty -Path $svcKey -ErrorAction SilentlyContinue
    if ($sk -and ($sk.PSObject.Properties.Name -contains 'DelayedAutostart') -and $sk.DelayedAutostart -eq 1) { $delayed = $true }
    $startText = "$($svc.StartType)$(if ($delayed) { ' (Delayed)' })"
    if ($svc.StartType -eq 'Disabled') {
        Add-Finding -Area "Service:$svcName" -Status "ERROR" -Detail "Disabled ($($svc.Status))" -Fix "Fix 1"
    } elseif ($svc.Status -ne 'Running' -and $svcName -ne 'NlaSvc') {
        Add-Finding -Area "Service:$svcName" -Status "ERROR" -Detail "$($svc.Status), start $startText" -Fix "Fix 1"
    } elseif ($svc.Status -ne 'Running') {
        # On some newer builds NlaSvc is Manual/Stopped with netprofm hosting identification
        Add-Finding -Area "Service:$svcName" -Status "WARN" -Detail "$($svc.Status), start $startText (check netprofm is Running)" -Fix "Fix 1"
    } else {
        Add-Finding -Area "Service:$svcName" -Status "OK" -Detail "Running, start $startText"
    }
}

$nlaParams = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters' -ErrorAction SilentlyContinue
$aedc = $null
if ($nlaParams -and ($nlaParams.PSObject.Properties.Name -contains 'AlwaysExpectDomainController')) { $aedc = $nlaParams.AlwaysExpectDomainController }
if ($null -ne $aedc) {
    Add-Finding -Area "NlaSvcParams" -Status "INFO" -Detail "AlwaysExpectDomainController = $aedc (community workaround present)"
} else {
    Add-Finding -Area "NlaSvcParams" -Status "INFO" -Detail "AlwaysExpectDomainController not set"
}

# ---------------- Detect: categories & firewall ----------------
$profiles = Get-InterfaceCategories
$nonDomain = @($profiles | Where-Object { $_.NetworkCategory -ne 'DomainAuthenticated' })
if ($profiles.Count -eq 0) {
    Add-Finding -Area "Category" -Status "ERROR" -Detail "No connection profiles returned (no connected interfaces or identification service down)" -Fix "Fix 1"
}
foreach ($p in $profiles) {
    if ($p.NetworkCategory -eq 'DomainAuthenticated') {
        Add-Finding -Area "Category:$($p.InterfaceAlias)" -Status "OK" -Detail "DomainAuthenticated ($($p.Name))"
    } else {
        $st = if ($cs.PartOfDomain) { "WARN" } else { "INFO" }
        Add-Finding -Area "Category:$($p.InterfaceAlias)" -Status $st -Detail "$($p.NetworkCategory) - network '$($p.Name)'" -Fix "Fix 1 / Fix 5 if no DC path by design"
    }
}
try {
    $fw = Get-NetFirewallSetting -PolicyStore ActiveStore
    $active = [string]$fw.ActiveProfile
    $st = if ($active -match 'Public|Private') { "WARN" } else { "OK" }
    Add-Finding -Area "FirewallActiveProfile" -Status $st -Detail $active
} catch {
    Add-Finding -Area "FirewallActiveProfile" -Status "WARN" -Detail "Could not read ActiveStore: $($_.Exception.Message)"
}

# DNS servers per interface
$dnsByIf = @{}
foreach ($d in @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses })) {
    $dnsByIf[$d.InterfaceAlias] = @($d.ServerAddresses)
}
foreach ($p in $profiles) {
    $servers = @()
    if ($dnsByIf.ContainsKey($p.InterfaceAlias)) { $servers = $dnsByIf[$p.InterfaceAlias] }
    $txt = if ($servers.Count) { $servers -join ', ' } else { '(none)' }
    $publicDns = @($servers | Where-Object { $_ -in @('8.8.8.8','8.8.4.4','1.1.1.1','1.0.0.1','9.9.9.9','208.67.222.222','208.67.220.220') })
    if ($publicDns.Count) {
        Add-Finding -Area "DNS:$($p.InterfaceAlias)" -Status "ERROR" -Detail "Public resolver(s) configured: $txt - cannot resolve AD SRV records" -Fix "Fix 4"
    } else {
        Add-Finding -Area "DNS:$($p.InterfaceAlias)" -Status "INFO" -Detail $txt
    }
}

# DC resolver ordering
if ($isDC) {
    $myIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
    foreach ($k in $dnsByIf.Keys) {
        $list = @($dnsByIf[$k])
        if ($list.Count -eq 0) { continue }
        $selfOnly = (@($list | Where-Object { $_ -notin $myIPs -and $_ -ne '127.0.0.1' }).Count -eq 0)
        if ($selfOnly) {
            Add-Finding -Area "DCDnsOrder:$k" -Status "WARN" -Detail "DC resolves only via itself ($($list -join ', ')) - add a partner DC first, loopback last" -Fix "Fix 3"
        } elseif ($list[0] -eq '127.0.0.1' -or $list[0] -in $myIPs) {
            Add-Finding -Area "DCDnsOrder:$k" -Status "WARN" -Detail "Self/loopback is primary ($($list -join ', ')) - partner DC should be first" -Fix "Fix 3"
        } else {
            Add-Finding -Area "DCDnsOrder:$k" -Status "OK" -Detail ($list -join ', ')
        }
    }
}

# ---------------- Detect: DC locator ----------------
$locatedDC = $null
if ($cs.PartOfDomain) {
    # PS 5.1: native stderr redirected under EAP=Stop throws NativeCommandError - relax locally
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $nl = (& nltest.exe "/dsgetdc:$domain" /force 2>&1 | Out-String)
    $nlExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($nlExit -eq 0 -and $nl -match 'DC:\s*\\\\(\S+)') {
        $locatedDC = $Matches[1]
        Add-Finding -Area "DCLocator" -Status "OK" -Detail "nltest /dsgetdc /force returned $locatedDC"
    } else {
        $err = ($nl -split "`r?`n" | Where-Object { $_ -match 'ERROR|Status' } | Select-Object -First 1)
        Add-Finding -Area "DCLocator" -Status "ERROR" -Detail "nltest /dsgetdc failed: $($err)" -Fix "Fix 4"
    }

    try {
        $srv = @(Resolve-DnsName -Type SRV -Name "_ldap._tcp.dc._msdcs.$domain" -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' })
        Add-Finding -Area "SRVRecords" -Status "OK" -Detail ("{0} DC SRV record(s): {1}" -f $srv.Count, (($srv | Select-Object -ExpandProperty NameTarget) -join ', '))
    } catch {
        Add-Finding -Area "SRVRecords" -Status "ERROR" -Detail "SRV lookup failed: $($_.Exception.Message)" -Fix "Fix 4"
    }

    if ($locatedDC) {
        $tnc = Test-NetConnection -ComputerName $locatedDC -Port 389 -WarningAction SilentlyContinue
        if ($tnc.TcpTestSucceeded) {
            Add-Finding -Area "LDAP389" -Status "OK" -Detail "TCP 389 to $locatedDC reachable (UDP 389 inferred from nltest success)"
        } else {
            Add-Finding -Area "LDAP389" -Status "ERROR" -Detail "TCP 389 to $locatedDC failed" -Fix "Fix 4"
        }
    }
}

# Locator works now but category is not domain => timing
if ($locatedDC -and $nonDomain.Count -gt 0) {
    Add-Finding -Area "Verdict" -Status "WARN" -Detail "DC reachable now but $($nonDomain.Count) interface(s) not DomainAuthenticated - detection failed at connect/boot time (timing / negative cache) or interface has no DC path by design" -Fix $(if ($isDC) { "Fix 1 then Fix 3" } else { "Fix 1 then Fix 2" })
}

# ---------------- Detect: events ----------------
try {
    $ev = @(Get-WinEvent -LogName 'Microsoft-Windows-NetworkProfile/Operational' -MaxEvents $EventCount -ErrorAction Stop |
        Where-Object { $_.Id -eq 10000 })
    foreach ($e in ($ev | Select-Object -First 5)) {
        $cat = if ($e.Message -match 'Category:\s*(\S+)') { $Matches[1] } else { '?' }
        $nm  = if ($e.Message -match 'Name:\s*(.+)') { $Matches[1].Trim() } else { '?' }
        Add-Finding -Area "Event10000" -Status "INFO" -Detail ("{0:yyyy-MM-dd HH:mm:ss} connected '{1}' category {2}" -f $e.TimeCreated, $nm, $cat)
    }
} catch {
    Add-Finding -Area "Event10000" -Status "INFO" -Detail "NetworkProfile/Operational not readable: $($_.Exception.Message)"
}

# ---------------- Execute (optional) ----------------
if ($Remediate) {
    Write-Status "Remediate: forcing DC re-discovery and restarting NlaSvc (Fix 1)" "WARN"
    if ($cs.PartOfDomain) {
        $ErrorActionPreference = 'Continue'
        & nltest.exe "/dsgetdc:$domain" /force 2>&1 | Out-Null
        $ErrorActionPreference = 'Stop'
    }
    try {
        Restart-Service -Name NlaSvc -Force
        Start-Sleep -Seconds 10
        # ---------------- Validate ----------------
        foreach ($p in (Get-InterfaceCategories)) {
            $st = if ($p.NetworkCategory -eq 'DomainAuthenticated') { "OK" } else { "WARN" }
            Add-Finding -Area "PostFix:$($p.InterfaceAlias)" -Status $st -Detail "$($p.NetworkCategory) - '$($p.Name)'" -Fix $(if ($st -eq 'WARN') { "Fix 2/3/5" } else { "" })
        }
    } catch {
        Add-Finding -Area "Remediate" -Status "ERROR" -Detail "NlaSvc restart failed: $($_.Exception.Message) - use Restart-NetAdapter from console" -Fix "Fix 1"
    }
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath ("NLADomainDetection-{0}-{1:yyyyMMdd-HHmmss}.csv" -f $env:COMPUTERNAME, (Get-Date))
$Findings | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$err = @($Findings | Where-Object Status -eq 'ERROR').Count
$warn = @($Findings | Where-Object Status -eq 'WARN').Count
Write-Status ("Summary: {0} ERROR, {1} WARN. Report: {2}" -f $err, $warn, $csv) $(if ($err) { "ERROR" } elseif ($warn) { "WARN" } else { "OK" })
