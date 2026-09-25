<#
.SYNOPSIS
    Read-only health check for RD Web Access servers, the workspace feed and the HTML5 web client.

.DESCRIPTION
    Companion to Windows/Troubleshooting/RDWebAccess-A.md / -B.md.
    For each RD Web Access server (locally or via PowerShell remoting) it checks:
      - RDS-Web-Access role installed, W3SVC / WAS service state, RDWebAccess app pool state
      - Certificate bound to IIS 443: expiry, days left, SAN and (optionally) whether it covers ExpectedFqdn
      - PasswordChangeEnabled app setting on /RDWeb/Pages
      - Whether the HTML5 web client is published (webclient\index.html present) and the
        installed package versions (Get-RDWebClientPackage, if the module is present)
      - Local HTTPS probe of /RDWeb/Pages/en-US/login.aspx and /RDWeb/Feed/webfeed.aspx
    If -ConnectionBroker is supplied (and the RemoteDesktop module is available where the script runs) it
    also reports deployment role membership, the four deployment certificates (Level / expiry /
    thumbprint), licensing mode (web client requires Per User) and the deployment gateway.
    If -EmailDomain is supplied it resolves the _msradc TXT discovery record.

    Does NOT change configuration. Does NOT validate the broker .cer imported into the web client
    (compare the thumbprint shown in the user's error with the RDRedirector row manually).
    Does NOT test from the internet or evaluate gateway CAP/RAP (use Get-RDGatewayDiagnostics.ps1).

.PARAMETER ComputerName
    One or more RD Web Access servers. Default: local computer.

.PARAMETER ExpectedFqdn
    Public FQDN users browse to (e.g. remote.contoso.com). Used for SAN validation and HTTPS probes.

.PARAMETER ConnectionBroker
    Active Connection Broker FQDN. Optional; enables deployment-level checks.

.PARAMETER EmailDomain
    Email domain used for workspace discovery (checks _msradc.<domain> TXT). Optional.

.PARAMETER CertWarningDays
    Warn when any certificate expires within this many days. Default 30.

.PARAMETER OutputPath
    Folder for the CSV reports. Default: C:\Temp

.EXAMPLE
    .\Get-RDWebAccessDiagnostics.ps1 -ExpectedFqdn remote.contoso.com

.EXAMPLE
    .\Get-RDWebAccessDiagnostics.ps1 -ComputerName RDWEB01,RDWEB02 -ExpectedFqdn remote.contoso.com -ConnectionBroker rdcb01.contoso.local -EmailDomain contoso.com

.NOTES
    Requires: local admin on each RD Web server; WinRM for remote targets; WebAdministration module on
    targets; RemoteDesktop module where the script runs for -ConnectionBroker checks.
    Run in Windows PowerShell 5.1 (RDWebClientManagement does not load in PowerShell 7).
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ExpectedFqdn,
    [string]$ConnectionBroker,
    [string]$EmailDomain,
    [ValidateRange(1, 365)][int]$CertWarningDays = 30,
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
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Status "Running in PowerShell $($PSVersionTable.PSVersion) - web client package checks need Windows PowerShell 5.1" "WARN"
}
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------- Collector (runs on each RD Web server) ----------
$collector = {
    param([string]$ExpectedFqdn)
    $ErrorActionPreference = 'Stop'
    $r = [ordered]@{
        Computer = $env:COMPUTERNAME; RoleInstalled = $false; W3SVC = ''; WAS = ''; AppPool = ''
        CertThumbprint = ''; CertSubject = ''; CertNotAfter = $null; CertDaysLeft = $null; CertSAN = ''
        SanMatchesFqdn = $null; PasswordChangeEnabled = ''; WebClientPublished = $false
        WebClientPackages = ''; LoginProbe = ''; FeedProbe = ''; Errors = ''
    }
    $errs = New-Object System.Collections.Generic.List[string]

    try { $r.RoleInstalled = [bool](Get-WindowsFeature -Name RDS-Web-Access).Installed }
    catch { $errs.Add("Feature: $($_.Exception.Message)") }

    foreach ($s in 'W3SVC','WAS') {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        $r[$s] = if ($svc) { [string]$svc.Status } else { 'NotPresent' }
    }

    $iis = $false
    try { Import-Module WebAdministration -ErrorAction Stop; $iis = $true }
    catch { $errs.Add("WebAdministration: $($_.Exception.Message)") }

    if ($iis) {
        try { $r.AppPool = [string](Get-WebAppPoolState -Name 'RDWebAccess').Value }
        catch { $r.AppPool = 'NotFound'; $errs.Add("AppPool: $($_.Exception.Message)") }

        try {
            $b = @(Get-ChildItem IIS:\SslBindings | Where-Object { $_.Port -eq 443 }) | Select-Object -First 1
            if ($b) { $r.CertThumbprint = [string]$b.Thumbprint }
        } catch { $errs.Add("SslBindings: $($_.Exception.Message)") }

        try {
            $p = Get-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site\RDWeb\Pages' `
                -Filter "appSettings/add[@key='PasswordChangeEnabled']" -Name value
            if ($null -ne $p) {
                if ($p -is [string]) { $r.PasswordChangeEnabled = $p } else { $r.PasswordChangeEnabled = [string]$p.Value }
            }
        } catch { $errs.Add("PasswordChangeEnabled: $($_.Exception.Message)") }
    }

    if ($r.CertThumbprint) {
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -ieq $r.CertThumbprint } | Select-Object -First 1
        if ($cert) {
            $r.CertSubject  = $cert.Subject
            $r.CertNotAfter = $cert.NotAfter
            $r.CertDaysLeft = [int]($cert.NotAfter - (Get-Date)).TotalDays
            $sans = @($cert.DnsNameList | ForEach-Object { $_.Unicode })
            $r.CertSAN = $sans -join ';'
            if ($ExpectedFqdn) {
                $m = $false
                foreach ($s in $sans) {
                    if ($s -ieq $ExpectedFqdn) { $m = $true }
                    elseif ($s.StartsWith('*.')) {
                        $i = $ExpectedFqdn.IndexOf('.')
                        if ($i -gt 0 -and $ExpectedFqdn.Substring($i) -ieq $s.Substring(1)) { $m = $true }
                    }
                }
                $r.SanMatchesFqdn = $m
            }
        } else { $errs.Add("Bound cert $($r.CertThumbprint) not in LocalMachine\My") }
    }

    $r.WebClientPublished = Test-Path 'C:\Windows\Web\RDWeb\webclient\index.html'
    try {
        Import-Module RDWebClientManagement -ErrorAction Stop
        $pk = @(Get-RDWebClientPackage)
        $r.WebClientPackages = (@($pk | ForEach-Object { "$($_.packageType):$($_.version)" }) -join '; ')
    } catch { $r.WebClientPackages = 'module not available' }

    # Local HTTPS probes (host header = expected FQDN if given)
    $probeHost = if ($ExpectedFqdn) { $ExpectedFqdn } else { "$env:COMPUTERNAME" }
    foreach ($pair in @(@('LoginProbe','/RDWeb/Pages/en-US/login.aspx'), @('FeedProbe','/RDWeb/Feed/webfeed.aspx'))) {
        try {
            $resp = Invoke-WebRequest -Uri ("https://{0}{1}" -f $probeHost, $pair[1]) -UseBasicParsing -UseDefaultCredentials -TimeoutSec 15
            $r[$pair[0]] = [string]$resp.StatusCode
        } catch {
            $code = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = $null }
            }
            if ($code) { $r[$pair[0]] = [string]$code } else { $r[$pair[0]] = "FAIL: $($_.Exception.Message)" }
        }
    }

    $r.Errors = $errs -join ' | '
    [pscustomobject]$r
}

# ---------- Execute per server ----------
$results = foreach ($c in $ComputerName) {
    Write-Status "Checking RD Web server $c"
    try {
        if ($c -ieq $env:COMPUTERNAME -or $c -ieq 'localhost') { & $collector $ExpectedFqdn }
        else { Invoke-Command -ComputerName $c -ScriptBlock $collector -ArgumentList $ExpectedFqdn -ErrorAction Stop |
                Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName }
    } catch {
        Write-Status "$c unreachable: $($_.Exception.Message)" "ERROR"
        [pscustomobject]@{ Computer = $c; Errors = "Unreachable: $($_.Exception.Message)" }
    }
}

# ---------- Validate / report per server ----------
foreach ($r in $results) {
    if (-not $r.PSObject.Properties['RoleInstalled']) { continue }
    if (-not $r.RoleInstalled) { Write-Status "$($r.Computer): RDS-Web-Access role NOT installed" "ERROR" }
    if ($r.AppPool -ne 'Started') { Write-Status "$($r.Computer): RDWebAccess app pool = '$($r.AppPool)' (expect Started; 503 to users)" "ERROR" }
    if (-not $r.CertThumbprint) { Write-Status "$($r.Computer): no certificate bound on 443" "ERROR" }
    elseif ($null -ne $r.CertDaysLeft) {
        if ($r.CertDaysLeft -lt 0) { Write-Status "$($r.Computer): RD Web cert EXPIRED ($($r.CertNotAfter))" "ERROR" }
        elseif ($r.CertDaysLeft -lt $CertWarningDays) { Write-Status "$($r.Computer): RD Web cert expires in $($r.CertDaysLeft) days" "WARN" }
        else { Write-Status "$($r.Computer): RD Web cert OK ($($r.CertDaysLeft) days)" "OK" }
    }
    if ($r.SanMatchesFqdn -eq $false) { Write-Status "$($r.Computer): cert SAN [$($r.CertSAN)] does not cover $ExpectedFqdn" "ERROR" }
    if ($r.LoginProbe -ne '200') { Write-Status "$($r.Computer): login.aspx probe = $($r.LoginProbe)" "WARN" }
    if ($r.FeedProbe -notin '200','401') { Write-Status "$($r.Computer): webfeed.aspx probe = $($r.FeedProbe)" "WARN" }
    if ($r.WebClientPublished) { Write-Status "$($r.Computer): HTML5 web client published ($($r.WebClientPackages))" "OK" }
    else { Write-Status "$($r.Computer): HTML5 web client not published" "INFO" }
    if ($r.Errors) { Write-Status "$($r.Computer): collector notes: $($r.Errors)" "WARN" }
}
$csv = Join-Path $OutputPath "RDWebAccessDiagnostics-Servers-$stamp.csv"
$results | Export-Csv -Path $csv -NoTypeInformation
Write-Status "Server report: $csv" "OK"

# ---------- Deployment-level checks ----------
if ($ConnectionBroker) {
    $dep = New-Object System.Collections.Generic.List[object]
    try {
        Import-Module RemoteDesktop -ErrorAction Stop
        $servers = @(Get-RDServer -ConnectionBroker $ConnectionBroker)
        $webNodes = @($servers | Where-Object { @($_.Roles) -contains 'RDS-WEB-ACCESS' } | ForEach-Object { $_.Server })
        foreach ($c in $ComputerName) {
            $listed = [bool](@($webNodes | Where-Object { $_ -ieq $c -or $_.Split('.')[0] -ieq $c.Split('.')[0] }).Count)
            $st = if ($listed) { 'OK' } else { 'ERROR' }
            Write-Status "$c listed in deployment as RDS-WEB-ACCESS: $listed" $st
            $dep.Add([pscustomobject]@{ Check = "DeploymentMember:$c"; Value = $listed; Detail = ($webNodes -join ';') })
        }

        foreach ($cert in @(Get-RDCertificate -ConnectionBroker $ConnectionBroker)) {
            $days = $null
            if ($cert.ExpiresOn) { $days = [int]($cert.ExpiresOn - (Get-Date)).TotalDays }
            $st = 'OK'
            if ([string]$cert.Level -ne 'Trusted') { $st = 'WARN' }
            if ($null -eq $days) { $st = 'WARN' } elseif ($days -lt 0) { $st = 'ERROR' } elseif ($days -lt $CertWarningDays -and $st -eq 'OK') { $st = 'WARN' }
            Write-Status "Deployment cert $($cert.Role): Level=$($cert.Level) DaysLeft=$days Thumb=$($cert.Thumbprint)" $st
            $dep.Add([pscustomobject]@{ Check = "Cert:$($cert.Role)"; Value = "$($cert.Level)/$days days"; Detail = "$($cert.Thumbprint) $($cert.Subject)" })
        }
        $thumbs = @(Get-RDCertificate -ConnectionBroker $ConnectionBroker | Where-Object { $_.Thumbprint } | ForEach-Object { $_.Thumbprint } | Select-Object -Unique)
        if ($thumbs.Count -gt 1) { Write-Status "Deployment roles use $($thumbs.Count) different certs - renewals must be coordinated (and re-import broker .cer for the web client)" "INFO" }

        try {
            $lic = Get-RDLicenseConfiguration -ConnectionBroker $ConnectionBroker
            $mode = [string]$lic.Mode
            $st = if ($mode -eq 'PerUser') { 'OK' } else { 'WARN' }
            Write-Status "Licensing mode: $mode (HTML5 web client requires PerUser)" $st
            $dep.Add([pscustomobject]@{ Check = 'LicensingMode'; Value = $mode; Detail = (@($lic.LicenseServer) -join ';') })
        } catch { Write-Status "Licensing query failed: $($_.Exception.Message)" "WARN" }

        try {
            $gw = Get-RDDeploymentGatewayConfiguration -ConnectionBroker $ConnectionBroker
            Write-Status "Deployment gateway: mode=$($gw.GatewayMode) external=$($gw.GatewayExternalFqdn)" "INFO"
            $dep.Add([pscustomobject]@{ Check = 'Gateway'; Value = [string]$gw.GatewayMode; Detail = [string]$gw.GatewayExternalFqdn })
        } catch { Write-Status "Gateway config query failed: $($_.Exception.Message)" "WARN" }
    } catch {
        Write-Status "Deployment checks skipped: $($_.Exception.Message)" "WARN"
    }

    if ($EmailDomain) {
        try {
            $txt = @(Resolve-DnsName -Name "_msradc.$EmailDomain" -Type TXT -ErrorAction Stop | Where-Object { $_.Type -eq 'TXT' })
            $val = (@($txt | ForEach-Object { $_.Strings -join '' }) -join ';')
            Write-Status "_msradc.$EmailDomain TXT = $val" "OK"
            $dep.Add([pscustomobject]@{ Check = 'EmailDiscovery'; Value = 'Present'; Detail = $val })
        } catch {
            Write-Status "_msradc.$EmailDomain TXT not found - email-based workspace discovery will fail" "WARN"
            $dep.Add([pscustomobject]@{ Check = 'EmailDiscovery'; Value = 'Missing'; Detail = '' })
        }
    }

    if ($dep.Count -gt 0) {
        $dcsv = Join-Path $OutputPath "RDWebAccessDiagnostics-Deployment-$stamp.csv"
        $dep | Export-Csv -Path $dcsv -NoTypeInformation
        Write-Status "Deployment report: $dcsv" "OK"
    }
} elseif ($EmailDomain) {
    Write-Status "EmailDomain supplied without ConnectionBroker - resolving discovery record only" "INFO"
    try {
        $txt = @(Resolve-DnsName -Name "_msradc.$EmailDomain" -Type TXT -ErrorAction Stop | Where-Object { $_.Type -eq 'TXT' })
        Write-Status "_msradc.$EmailDomain TXT = $((@($txt | ForEach-Object { $_.Strings -join '' })) -join ';')" "OK"
    } catch { Write-Status "_msradc.$EmailDomain TXT not found" "WARN" }
}
