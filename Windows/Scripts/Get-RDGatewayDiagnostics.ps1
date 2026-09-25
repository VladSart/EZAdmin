<#
.SYNOPSIS
    Read-only health and failure-pattern check for one or more RD Gateway servers.

.DESCRIPTION
    Companion to Windows/Troubleshooting/RDGateway-A.md / -B.md.
    For each gateway (locally or via PowerShell remoting) it checks:
      - RDS-Gateway role, TSGateway / IAS / W3SVC service state
      - Configured SSL certificate thumbprint vs the HTTP.sys 0.0.0.0:443 binding,
        certificate expiry, private key and whether the SAN contains the expected FQDN
      - CAP store mode (local vs central NPS), enabled CAP / RAP counts, and
        RAPs that allow "any network resource"
      - UDP transport setting
      - Operational log counts for the last N hours: 200 (auth ok), 201 (CAP fail),
        301 (RAP fail), 302 (connected), 304 (resource unreachable), 303 (disconnect)
      - Top users producing 201/301 failures (spray / misconfig indicator)
    Optionally tests TCP reachability from the gateway to supplied target hosts on 3389.

    Does NOT change any configuration. Does NOT inspect central NPS servers (run
    NPS-side checks from NPS-RADIUS-B.md there). Does NOT test from the internet.

.PARAMETER ComputerName
    One or more RD Gateway servers. Default: local computer.

.PARAMETER ExpectedFqdn
    Public FQDN users connect to. Used to validate the certificate SAN. Optional.

.PARAMETER Hours
    Look-back window for event analysis. Default 24.

.PARAMETER TestTarget
    Optional internal hosts to test on TCP 3389 from each gateway.

.PARAMETER OutputPath
    Folder for the CSV report. Default: C:\Temp

.EXAMPLE
    .\Get-RDGatewayDiagnostics.ps1 -ExpectedFqdn rdg.contoso.com

.EXAMPLE
    .\Get-RDGatewayDiagnostics.ps1 -ComputerName RDG01,RDG02 -ExpectedFqdn rdg.contoso.com -TestTarget rdsh01.contoso.local -Hours 72

.NOTES
    Requires: local admin on each gateway; WinRM for remote targets; RemoteDesktopServices module on the gateway.
    Safe: read-only. PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ExpectedFqdn,
    [ValidateRange(1, 720)][int]$Hours = 24,
    [string[]]$TestTarget = @(),
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path $OutputPath "RDGatewayDiagnostics-$stamp.csv"

# ---------- Collector (runs on each gateway) ----------
$collector = {
    param([string]$ExpectedFqdn, [int]$Hours, [string[]]$TestTarget)
    $ErrorActionPreference = 'Stop'
    $r = [ordered]@{
        Computer = $env:COMPUTERNAME; RoleInstalled = $false; TSGateway = ''; IAS = ''; W3SVC = ''
        CertThumbprint = ''; HttpSysThumbprint = ''; CertBindingMatch = $false; CertNotAfter = $null
        CertDaysLeft = $null; CertHasPrivateKey = $false; CertSAN = ''; SanMatchesFqdn = $null
        CentralCAP = $null; CAPsEnabled = 0; RAPsEnabled = 0; RAPsAnyResource = 0; UdpEnabled = ''
        Ev200 = 0; Ev201 = 0; Ev301 = 0; Ev302 = 0; Ev303 = 0; Ev304 = 0
        TopFailUsers = ''; TargetTests = ''; Errors = ''
    }
    $errs = New-Object System.Collections.Generic.List[string]

    try {
        $f = Get-WindowsFeature -Name RDS-Gateway -ErrorAction Stop
        $r.RoleInstalled = [bool]$f.Installed
    } catch { $errs.Add("Feature: $($_.Exception.Message)") }

    foreach ($s in 'TSGateway','IAS','W3SVC') {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        $r[$s] = if ($svc) { [string]$svc.Status } else { 'NotPresent' }
    }

    $rdsLoaded = $false
    try { Import-Module RemoteDesktopServices -ErrorAction Stop; $rdsLoaded = $true }
    catch { $errs.Add("RemoteDesktopServices module: $($_.Exception.Message)") }

    if ($rdsLoaded) {
        try { $r.CertThumbprint = [string](Get-Item 'RDS:\GatewayServer\SSLCertificate\Thumbprint').CurrentValue } catch { $errs.Add("Thumbprint: $($_.Exception.Message)") }
        try { $r.CentralCAP = [string](Get-Item 'RDS:\GatewayServer\CentralCAPEnabled').CurrentValue } catch { $errs.Add("CentralCAP: $($_.Exception.Message)") }

        try {
            foreach ($cap in @(Get-ChildItem 'RDS:\GatewayServer\CAP' -ErrorAction Stop)) {
                $st = (Get-Item (Join-Path $cap.PSPath 'Status')).CurrentValue
                if ([string]$st -eq '1') { $r.CAPsEnabled++ }
            }
        } catch { $errs.Add("CAP: $($_.Exception.Message)") }

        try {
            foreach ($rap in @(Get-ChildItem 'RDS:\GatewayServer\RAP' -ErrorAction Stop)) {
                $st = (Get-Item (Join-Path $rap.PSPath 'Status')).CurrentValue
                if ([string]$st -eq '1') {
                    $r.RAPsEnabled++
                    $gt = (Get-Item (Join-Path $rap.PSPath 'ComputerGroupType')).CurrentValue
                    if ([string]$gt -eq '2') { $r.RAPsAnyResource++ }
                }
            }
        } catch { $errs.Add("RAP: $($_.Exception.Message)") }

        try {
            $udpItem = Get-ChildItem 'RDS:\GatewayServer\Transport' -Recurse -ErrorAction Stop |
                Where-Object { $_.PSPath -match '\\UDP\\' -and $_.Name -eq 'Enabled' } | Select-Object -First 1
            if ($udpItem) { $r.UdpEnabled = [string](Get-Item $udpItem.PSPath).CurrentValue } else { $r.UdpEnabled = 'unknown' }
        } catch { $r.UdpEnabled = 'unknown' }
    }

    # HTTP.sys binding
    try {
        $ns = netsh http show sslcert ipport=0.0.0.0:443 2>$null
        $line = $ns | Where-Object { $_ -match 'Certificate Hash' } | Select-Object -First 1
        if ($line) { $r.HttpSysThumbprint = ($line -split ':',2)[1].Trim() }
    } catch { $errs.Add("netsh: $($_.Exception.Message)") }
    if ($r.CertThumbprint -and $r.HttpSysThumbprint) {
        $r.CertBindingMatch = ($r.CertThumbprint -ieq $r.HttpSysThumbprint)
    }

    # Certificate
    if ($r.CertThumbprint) {
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -ieq $r.CertThumbprint } | Select-Object -First 1
        if ($cert) {
            $r.CertNotAfter      = $cert.NotAfter
            $r.CertDaysLeft      = [int]($cert.NotAfter - (Get-Date)).TotalDays
            $r.CertHasPrivateKey = [bool]$cert.HasPrivateKey
            $sans = @($cert.DnsNameList | ForEach-Object { $_.Unicode })
            $r.CertSAN = $sans -join ';'
            if ($ExpectedFqdn) {
                $match = $false
                foreach ($s in $sans) {
                    if ($s -ieq $ExpectedFqdn) { $match = $true }
                    elseif ($s -like '`*.*') {
                        $suffix = $s.Substring(1)
                        $host1  = $ExpectedFqdn.Split('.')[0]
                        if ($ExpectedFqdn -ieq ($host1 + $suffix)) { $match = $true }
                    }
                }
                $r.SanMatchesFqdn = $match
            }
        } else { $errs.Add("Configured cert $($r.CertThumbprint) not found in LocalMachine\My") }
    }

    # Events
    try {
        $start = (Get-Date).AddHours(-$Hours)
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-TerminalServices-Gateway/Operational'; Id=200,201,301,302,303,304; StartTime=$start } -ErrorAction Stop)
        foreach ($id in 200,201,301,302,303,304) { $r["Ev$id"] = @($ev | Where-Object { $_.Id -eq $id }).Count }
        $fails = @($ev | Where-Object { $_.Id -in 201,301 })
        if ($fails.Count -gt 0) {
            $users = foreach ($e in $fails) {
                if ($e.Message -match 'user "([^"]+)"') { $Matches[1] } else { 'unparsed' }
            }
            $r.TopFailUsers = (@($users | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 |
                ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '; ')
        }
    } catch {
        if ($_.Exception.Message -notmatch 'No events were found') { $errs.Add("Events: $($_.Exception.Message)") }
    }

    # Gateway -> target
    if ($TestTarget.Count -gt 0) {
        $res = foreach ($t in $TestTarget) {
            $ok = $false
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $iar = $c.BeginConnect($t, 3389, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected) { $ok = $true }
                $c.Close()
            } catch { $ok = $false }
            "$t=$(if ($ok) {'OK'} else {'FAIL'})"
        }
        $r.TargetTests = $res -join '; '
    }

    $r.Errors = $errs -join ' | '
    [pscustomobject]$r
}

# ---------- Execute ----------
$results = New-Object System.Collections.Generic.List[object]
foreach ($cn in $ComputerName) {
    Write-Status "Collecting from $cn ..."
    try {
        if ($cn -ieq $env:COMPUTERNAME -or $cn -eq 'localhost' -or $cn -eq '.') {
            $o = & $collector $ExpectedFqdn $Hours $TestTarget
        } else {
            $o = Invoke-Command -ComputerName $cn -ScriptBlock $collector -ArgumentList $ExpectedFqdn, $Hours, $TestTarget
        }
        $results.Add($o)
    } catch {
        Write-Status "$cn : collection failed - $($_.Exception.Message)" "ERROR"
    }
}

# ---------- Validate / Report ----------
foreach ($r in $results) {
    Write-Host ""
    Write-Status "=== $($r.Computer) ===" "INFO"
    if (-not $r.RoleInstalled) { Write-Status "RDS-Gateway role not installed" "ERROR" }
    if ($r.TSGateway -ne 'Running') { Write-Status "TSGateway service: $($r.TSGateway)" "ERROR" } else { Write-Status "TSGateway running" "OK" }
    if ($r.CertThumbprint -and -not $r.CertBindingMatch) { Write-Status "RDG cert $($r.CertThumbprint) != HTTP.sys 443 binding $($r.HttpSysThumbprint) (Fix 2)" "ERROR" }
    if ($null -ne $r.CertDaysLeft) {
        if ($r.CertDaysLeft -lt 0) { Write-Status "Certificate EXPIRED ($($r.CertNotAfter))" "ERROR" }
        elseif ($r.CertDaysLeft -lt 30) { Write-Status "Certificate expires in $($r.CertDaysLeft) days" "WARN" }
        else { Write-Status "Certificate valid, $($r.CertDaysLeft) days left" "OK" }
    }
    if ($r.CertThumbprint -and -not $r.CertHasPrivateKey) { Write-Status "Certificate has no private key" "ERROR" }
    if ($r.SanMatchesFqdn -eq $false) { Write-Status "SAN ($($r.CertSAN)) does not cover $ExpectedFqdn" "ERROR" }
    if ([string]$r.CentralCAP -eq '1') { Write-Status "CAPs on CENTRAL NPS - local CAP count is irrelevant; check NPS server" "INFO" }
    elseif ($r.CAPsEnabled -eq 0) { Write-Status "No enabled local CAPs - every user will get Event 201" "ERROR" }
    if ($r.RAPsEnabled -eq 0) { Write-Status "No enabled RAPs - every connection will get Event 301" "ERROR" }
    if ($r.RAPsAnyResource -gt 0) { Write-Status "$($r.RAPsAnyResource) RAP(s) allow ANY network resource (hardening gap)" "WARN" }
    Write-Status ("Last {0}h: 200={1} 201={2} 301={3} 302={4} 304={5} 303={6}" -f $Hours,$r.Ev200,$r.Ev201,$r.Ev301,$r.Ev302,$r.Ev304,$r.Ev303)
    if (($r.Ev201 + $r.Ev301) -gt 50) { Write-Status "High CAP/RAP failure volume - check for password spray: $($r.TopFailUsers)" "WARN" }
    elseif ($r.TopFailUsers) { Write-Status "Failures by user: $($r.TopFailUsers)" "WARN" }
    if ($r.Ev304 -gt 0) { Write-Status "$($r.Ev304) x Event 304 - gateway cannot reach targets (Fix 7)" "WARN" }
    if ($r.TargetTests) {
        $st = if ($r.TargetTests -match 'FAIL') { 'WARN' } else { 'OK' }
        Write-Status "Gateway->target 3389: $($r.TargetTests)" $st
    }
    if ($r.Errors) { Write-Status "Collection notes: $($r.Errors)" "WARN" }
}

if ($results.Count -gt 0) {
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Status "Report saved: $csvPath" "OK"
} else {
    Write-Status "No results collected." "ERROR"
}
