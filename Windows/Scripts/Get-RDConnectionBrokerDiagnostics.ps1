<#
.SYNOPSIS
    Read-only health check of an RDS Connection Broker deployment (single broker or HA).

.DESCRIPTION
    Companion to Windows/Troubleshooting/RDConnectionBroker-A.md / -B.md.
    Collects, without changing anything:
      - HA configuration (active management server, client access name, broker list,
        database connection string with passwords masked, driver named in the string)
      - Per broker: Tssdis / RDMS / TScPubRPC service state, 64-bit SQL ODBC drivers installed,
        whether the driver named in the connection string is present, TCP 3389 reachability,
        SessionBroker/Admin error+warning count over the last N hours
      - SQL server TCP reachability (host/port parsed from the connection string)
      - Client access name DNS A records and TCP 3389 per returned IP
      - Deployment certificates (Role, Level, expiry, whether Subject/SAN covers the CAN)
      - Collection host drain state and user session counts
    Does NOT: test SQL logins/permissions, check SQL collation, change any setting,
    or validate RD Gateway / RD Web (see sibling scripts).

.PARAMETER ConnectionBroker
    FQDN of any broker in the deployment. Default: local computer FQDN.

.PARAMETER HoursBack
    Window for event log counts. Default 24.

.PARAMETER SqlPort
    Port to test if none is found in the connection string. Default 1433.

.PARAMETER OutputPath
    Folder for the CSV report. Default: C:\Temp.

.EXAMPLE
    .\Get-RDConnectionBrokerDiagnostics.ps1 -ConnectionBroker rdcb01.contoso.com -HoursBack 48

.NOTES
    Requires: Windows PowerShell 5.1, RemoteDesktop module, admin rights on the deployment,
    WinRM to each broker. Safe: read-only. Passwords in connection strings are masked in output.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConnectionBroker = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName),
    [ValidateRange(1, 720)][int]$HoursBack = 24,
    [int]$SqlPort = 1433,
    [string]$OutputPath = 'C:\Temp'
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
    param([string]$Area, [string]$Target, [string]$Check, [string]$Value, [string]$Status)
    $results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('s'); Area = $Area; Target = $Target
        Check = $Check; Value = $Value; Status = $Status })
    Write-Status "$Area | $Target | $Check : $Value" $Status
}
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}
function Hide-Secret {
    param([string]$Text)
    if (-not $Text) { return '' }
    return ($Text -replace '(?i)(pwd|password)\s*=\s*[^;]*', '$1=***')
}
function Test-Port {
    param([string]$HostName, [int]$Port)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if ($ok) { $c.EndConnect($iar) }
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

# ---------------- Preflight ----------------
Write-Status "Connection Broker diagnostics against $ConnectionBroker (last $HoursBack h)"
if ($PSVersionTable.PSVersion.Major -ne 5) { Write-Status 'RemoteDesktop module needs Windows PowerShell 5.1' 'WARN' }
try { Import-Module RemoteDesktop -ErrorAction Stop } catch {
    Write-Status "RemoteDesktop module not available: $($_.Exception.Message)" 'ERROR'; return }
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$since = (Get-Date).AddHours(-$HoursBack)

# ---------------- Detect: HA config ----------------
$ha = $null
try { $ha = Get-RDConnectionBrokerHighAvailability -ConnectionBroker $ConnectionBroker -ErrorAction Stop } catch {
    Add-Result 'HA' $ConnectionBroker 'Get-RDConnectionBrokerHighAvailability' $_.Exception.Message 'ERROR' }

$brokers = @($ConnectionBroker); $can = $null; $dbString = $null; $driverInString = $null; $sqlHost = $null; $sqlTestPort = $SqlPort
$activeMgmt = Get-Prop $ha 'ActiveManagementServer'
if ($ha -and $activeMgmt) {
    $brokers  = @(Get-Prop $ha 'ConnectionBroker') | Where-Object { $_ }
    $can      = Get-Prop $ha 'ClientAccessName'
    $dbString = Get-Prop $ha 'DatabaseConnectionString'
    Add-Result 'HA' $ConnectionBroker 'Mode' 'High availability (shared SQL)' 'OK'
    Add-Result 'HA' $ConnectionBroker 'ActiveManagementServer' "$activeMgmt" 'INFO'
    Add-Result 'HA' $ConnectionBroker 'Brokers' ($brokers -join ', ') $(if (@($brokers).Count -ge 2) {'OK'} else {'WARN'})
    Add-Result 'HA' $ConnectionBroker 'ClientAccessName' "$can" $(if ($can) {'OK'} else {'WARN'})
    Add-Result 'HA' $ConnectionBroker 'DatabaseConnectionString' (Hide-Secret $dbString) 'INFO'
    $sec = Get-Prop $ha 'DatabaseSecondaryConnectionString'
    Add-Result 'HA' $ConnectionBroker 'SecondaryConnectionString' $(if ($sec) {'present'} else {'not set'}) 'INFO'
    if ($dbString -match '(?i)driver\s*=\s*\{?([^;}]+)\}?') { $driverInString = $Matches[1].Trim() }
    if ($dbString -match '(?i)server\s*=\s*(tcp:)?([^;,\\]+)(\\[^;,]+)?(,(\d+))?') {
        $sqlHost = $Matches[2].Trim(); if ($Matches[5]) { $sqlTestPort = [int]$Matches[5] } }
    if ($dbString -cmatch 'Trusted_Connection=YES') { Add-Result 'HA' $ConnectionBroker 'Trusted_Connection casing' 'YES (should be Yes)' 'WARN' }
    if ($dbString -match '(?i)database\s*=\s*[^;]*\.mdf') { Add-Result 'HA' $ConnectionBroker 'Database name' 'contains .mdf extension' 'WARN' }
} else {
    Add-Result 'HA' $ConnectionBroker 'Mode' 'Single broker (WID) - no failover' 'WARN'
}

# ---------------- Detect: per broker ----------------
foreach ($b in $brokers) {
    $remote = $null
    try {
        $remote = Invoke-Command -ComputerName $b -ErrorAction Stop -ScriptBlock {
            $svc = Get-Service -Name Tssdis, RDMS, TScPubRPC -ErrorAction SilentlyContinue | Select-Object Name, Status
            $drv = @()
            try { $drv = @(Get-OdbcDriver -Platform 64-bit -ErrorAction Stop | Where-Object Name -match 'SQL' | Select-Object -ExpandProperty Name) } catch { }
            $wid = Get-Service -Name 'MSSQL$MICROSOFT##WID' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Status
            [pscustomobject]@{ Services = $svc; Drivers = $drv; Wid = "$wid" }
        }
    } catch {
        Add-Result 'Broker' $b 'WinRM' $_.Exception.Message 'ERROR'
    }
    if ($remote) {
        foreach ($s in @($remote.Services)) {
            $st = "$($s.Status)"
            $lvl = 'OK'
            if ($st -ne 'Running') {
                if ($s.Name -eq 'RDMS' -and $activeMgmt -and ($b -ne $activeMgmt)) { $lvl = 'INFO' } else { $lvl = 'ERROR' }
            }
            Add-Result 'Broker' $b "Service $($s.Name)" $st $lvl
        }
        Add-Result 'Broker' $b 'SQL ODBC drivers' ((@($remote.Drivers)) -join '; ') 'INFO'
        if ($driverInString) {
            $has = @($remote.Drivers) -contains $driverInString
            Add-Result 'Broker' $b "Driver '$driverInString' installed" "$has" $(if ($has) {'OK'} else {'ERROR'})
        } elseif (-not $activeMgmt) {
            Add-Result 'Broker' $b 'WID service' $remote.Wid $(if ($remote.Wid -eq 'Running') {'OK'} else {'ERROR'})
        }
    }
    $p = Test-Port -HostName $b -Port 3389
    Add-Result 'Broker' $b 'TCP 3389' "$p" $(if ($p) {'OK'} else {'ERROR'})
    try {
        $ev = @(Get-WinEvent -ComputerName $b -FilterHashtable @{
            LogName = 'Microsoft-Windows-TerminalServices-SessionBroker/Admin'; Level = 2, 3; StartTime = $since } -ErrorAction Stop)
        $err = @($ev | Where-Object Level -eq 2).Count
        Add-Result 'Broker' $b "SessionBroker/Admin errors/warnings ($HoursBack h)" "$err / $($ev.Count - $err)" $(if ($err -gt 0) {'WARN'} else {'OK'})
        if ($err -gt 0) {
            $first = ($ev | Where-Object Level -eq 2 | Select-Object -First 1)
            $msg = ($first.Message -split "`n")[0]
            Add-Result 'Broker' $b 'Latest error' "Id $($first.Id): $msg" 'WARN'
        }
    } catch {
        if ($_.Exception.Message -match 'No events were found') {
            Add-Result 'Broker' $b "SessionBroker/Admin errors/warnings ($HoursBack h)" '0 / 0' 'OK'
        } else { Add-Result 'Broker' $b 'SessionBroker/Admin log' $_.Exception.Message 'WARN' }
    }
}

# ---------------- Detect: SQL reachability ----------------
if ($sqlHost) {
    $ok = Test-Port -HostName $sqlHost -Port $sqlTestPort
    Add-Result 'SQL' $sqlHost "TCP $sqlTestPort from $env:COMPUTERNAME" "$ok" $(if ($ok) {'OK'} else {'ERROR'})
    if ($dbString -match '(?i)ODBC Driver 18' -and $dbString -notmatch '(?i)TrustServerCertificate\s*=\s*yes') {
        Add-Result 'SQL' $sqlHost 'ODBC 18 TLS' 'Encrypts by default - SQL cert must be trusted by brokers' 'INFO' }
}

# ---------------- Detect: client access name ----------------
if ($can) {
    try {
        $ips = @(Resolve-DnsName -Name $can -Type A -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] } | Select-Object -ExpandProperty IPAddress)
        Add-Result 'CAN' $can 'A records' ($ips -join ', ') $(if ($ips.Count -ge 1) {'OK'} else {'ERROR'})
        if ($ips.Count -eq 1 -and @($brokers).Count -gt 1) { Add-Result 'CAN' $can 'Topology' 'Single IP - LB VIP expected, else RR record missing' 'INFO' }
        foreach ($ip in $ips) {
            $ok = Test-Port -HostName $ip -Port 3389
            Add-Result 'CAN' $ip 'TCP 3389' "$ok" $(if ($ok) {'OK'} else {'ERROR'})
        }
    } catch { Add-Result 'CAN' $can 'DNS' $_.Exception.Message 'ERROR' }
}

# ---------------- Detect: certificates ----------------
try {
    $certs = @(Get-RDCertificate -ConnectionBroker $ConnectionBroker -ErrorAction Stop)
    foreach ($c in $certs) {
        $role = "$(Get-Prop $c 'Role')"; $level = "$(Get-Prop $c 'Level')"; $exp = Get-Prop $c 'ExpiresOn'; $subj = "$(Get-Prop $c 'Subject')"
        $days = if ($exp) { [int]((Get-Date $exp) - (Get-Date)).TotalDays } else { $null }
        $st = 'OK'
        if ($level -ne 'Trusted') { $st = 'WARN' }
        if ($null -ne $days -and $days -lt 30) { $st = 'WARN' }
        if ($null -ne $days -and $days -lt 0) { $st = 'ERROR' }
        Add-Result 'Cert' $role 'Level / days left / subject' "$level / $days / $subj" $st
        if ($can -and $role -in 'RDRedirector', 'RDPublishing') {
            $thumb = "$(Get-Prop $c 'Thumbprint')"
            $covers = $null
            if ($thumb) {
                try {
                    $covers = Invoke-Command -ComputerName $ConnectionBroker -ErrorAction Stop -ArgumentList $thumb, $can -ScriptBlock {
                        param($t, $n)
                        $x = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $t | Select-Object -First 1
                        if (-not $x) { return 'not-in-store' }
                        $names = @($x.DnsNameList | ForEach-Object { $_.Unicode })
                        $hit = $false
                        foreach ($d in $names) {
                            if ($d -ieq $n) { $hit = $true }
                            elseif ($d -like '`*.*' -and $n -like ('*' + $d.Substring(1))) { $hit = $true }
                        }
                        return "$hit"
                    }
                } catch { $covers = 'unknown' }
            }
            Add-Result 'Cert' $role "SAN covers $can" "$covers" $(if ($covers -eq 'True') {'OK'} elseif ($covers -eq 'False') {'ERROR'} else {'WARN'})
        }
    }
} catch { Add-Result 'Cert' $ConnectionBroker 'Get-RDCertificate' $_.Exception.Message 'WARN' }

# ---------------- Detect: collections / hosts / sessions ----------------
try {
    $cols = @(Get-RDSessionCollection -ConnectionBroker $ConnectionBroker -ErrorAction Stop)
    foreach ($col in $cols) {
        $hosts = @(Get-RDSessionHost -CollectionName $col.CollectionName -ConnectionBroker $ConnectionBroker -ErrorAction SilentlyContinue)
        $drain = @($hosts | Where-Object { "$($_.NewConnectionAllowed)" -ne 'Yes' })
        $st = 'OK'; if ($hosts.Count -gt 0 -and $drain.Count -eq $hosts.Count) { $st = 'ERROR' } elseif ($drain.Count -gt 0) { $st = 'WARN' }
        Add-Result 'Collection' $col.CollectionName 'Hosts / draining' "$($hosts.Count) / $($drain.Count) ($((@($drain | ForEach-Object { $_.SessionHost })) -join ','))" $st
    }
    $sess = @(Get-RDUserSession -ConnectionBroker $ConnectionBroker -ErrorAction SilentlyContinue)
    Add-Result 'Sessions' $ConnectionBroker 'Brokered sessions (active/disconnected)' "$(@($sess | Where-Object { "$($_.SessionState)" -eq 'STATE_ACTIVE' }).Count) / $(@($sess | Where-Object { "$($_.SessionState)" -eq 'STATE_DISCONNECTED' }).Count)" 'INFO'
} catch { Add-Result 'Collection' $ConnectionBroker 'Enumerate' $_.Exception.Message 'WARN' }

# ---------------- Report ----------------
$file = Join-Path $OutputPath ("Get-RDConnectionBrokerDiagnostics_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
$results | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
$errs = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. $errs error(s), $warns warning(s). Report: $file" $(if ($errs) {'ERROR'} elseif ($warns) {'WARN'} else {'OK'})
Write-Status 'Next: match findings to RDConnectionBroker-B.md triage table.'
