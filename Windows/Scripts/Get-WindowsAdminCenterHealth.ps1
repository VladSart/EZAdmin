<#
.SYNOPSIS
    Read-only health and evidence check for a Windows Admin Center (WAC) gateway and, optionally, its managed targets.

.DESCRIPTION
    Run on the WAC gateway host. The script:
      - Detects the WAC generation: modernized gateway (service "WindowsAdminCenter", 2410+) or legacy (service "ServerManagementGateway", 2311 and earlier).
      - Reports the installed file version, service state and start type.
      - Reads http.sys SSL bindings, then resolves each bound thumbprint in LocalMachine\My and checks
        expiry, private key, the Server Authentication EKU, whether the gateway FQDN is in the DNS names,
        and whether NETWORK SERVICE can read the private key (CNG and CAPI keys).
      - Lists listening TCP ports owned by WAC processes.
      - Reports the WAC login mode (if the v2 configuration module is present), WinRM TrustedHosts, and CredSSP client state.
      - Pulls recent Error/Warning events from the WindowsAdminCenter (v2) or Microsoft-ServerManagementExperience (v1) logs.
      - Tails Configuration.log (v2).
      - For each -Target: DNS, TCP 5985, Test-WSMan, HTTP SPN ownership (if setspn is available), and an optional Invoke-Command round trip.
    Every finding goes to a CSV. With -CollectLogs, the logs are also zipped.

    It changes nothing. It doesn't cover extension-level functional issues, HA cluster role health
    (it only flags whether HA cmdlets exist), or WAC in the Azure portal.

.PARAMETER Target
    One or more managed node names/FQDNs to test gateway → target connectivity.

.PARAMETER TestInvoke
    Also run a trivial Invoke-Command against each target, using the current user's credentials.

.PARAMETER OutputPath
    Folder for the CSV and the optional zip. Default: C:\Temp\WAC-Health

.PARAMETER CollectLogs
    Copy C:\ProgramData\WindowsAdminCenter\Logs, export the WAC event log, save netsh output, and zip everything.

.EXAMPLE
    .\Get-WindowsAdminCenterHealth.ps1

.EXAMPLE
    .\Get-WindowsAdminCenterHealth.ps1 -Target hv01.contoso.com, fs02.contoso.com -TestInvoke -CollectLogs

.NOTES
    Requires: Windows PowerShell 5.1, run elevated on the gateway (needed for the private-key ACL reads and some event logs).
    Safe: read-only. No service, certificate, WinRM or firewall changes.
    Written for WAC 2410/2511 (modernized gateway), with legacy detection included.
    Sources: learn.microsoft.com/windows-server/manage/windows-admin-center/support/troubleshooting and known-issues.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string[]]$Target,
    [switch]$TestInvoke,
    [string]$OutputPath = 'C:\Temp\WAC-Health',
    [switch]$CollectLogs
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
    param([string]$Area, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('s'); Host = $env:COMPUTERNAME
        Area = $Area; Check = $Check; Status = $Status; Detail = $Detail
    })
    Write-Status -Message "$Area | $Check : $Detail" -Status $Status
}

# ---------------- Preflight ----------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }
$fqdn = try { [System.Net.Dns]::GetHostEntry('').HostName } catch { $env:COMPUTERNAME }
Add-Result 'Host' 'Gateway FQDN' 'INFO' $fqdn

$os = Get-CimInstance Win32_OperatingSystem
Add-Result 'Host' 'OS' 'INFO' "$($os.Caption) build $($os.BuildNumber)"
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.DomainRole -ge 4) {
    Add-Result 'Host' 'Domain controller' 'WARN' 'Gateway is a domain controller. Microsoft does not support this; installer steps (CredSSP group, login mode) fail. Move WAC to a member server.'
} else {
    Add-Result 'Host' 'Domain role' 'OK' "DomainRole=$($cs.DomainRole) PartOfDomain=$($cs.PartOfDomain)"
}

# ---------------- Detect ----------------
$wacRoot = Join-Path $env:ProgramFiles 'WindowsAdminCenter'
$svcV2 = Get-Service -Name 'WindowsAdminCenter' -ErrorAction SilentlyContinue
$svcV1 = Get-Service -Name 'ServerManagementGateway' -ErrorAction SilentlyContinue
$generation = 'None'
if ($svcV2) { $generation = 'Modernized (v2)' } elseif ($svcV1) { $generation = 'Legacy (v1)' }
Add-Result 'Install' 'Generation' $(if ($generation -eq 'None') {'ERROR'} elseif ($svcV1 -and -not $svcV2) {'WARN'} else {'OK'}) $generation
if ($svcV1 -and $svcV2) { Add-Result 'Install' 'Mixed generations' 'WARN' 'Both ServerManagementGateway and WindowsAdminCenter services exist: half-migrated upgrade. Consider clean reinstall.' }

$exe = Join-Path $wacRoot 'WindowsAdminCenter.exe'
if (Test-Path $exe) {
    $ver = (Get-Item $exe).VersionInfo.FileVersion
    Add-Result 'Install' 'File version' 'INFO' $ver
}

foreach ($s in @($svcV2, $svcV1) | Where-Object { $_ }) {
    $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction SilentlyContinue
    $st = if ($s.Status -eq 'Running') {'OK'} else {'ERROR'}
    $detail = "Status=$($s.Status) StartMode=$(if ($wmiSvc) {$wmiSvc.StartMode} else {'?'}) Account=$(if ($wmiSvc) {$wmiSvc.StartName} else {'?'})"
    Add-Result 'Service' $s.Name $st $detail
}

# Listening ports owned by WAC processes
$wacProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'WindowsAdminCenter*' -or $_.ProcessName -eq 'sme' })
if ($wacProcs.Count -gt 0) {
    $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $wacProcs.Id -contains $_.OwningProcess } |
        Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
    Add-Result 'Network' 'WAC listening ports' $(if ($ports.Count) {'OK'} else {'WARN'}) ($(if ($ports.Count) { $ports -join ',' } else { 'none found (front end may be via http.sys; see SSL bindings)' }))
} else {
    Add-Result 'Network' 'WAC processes' 'WARN' 'No WindowsAdminCenter*/sme process running'
}

# Firewall rules mentioning Windows Admin Center
$fw = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*Windows Admin Center*' -and $_.Direction -eq 'Inbound' })
Add-Result 'Network' 'Inbound firewall rule' $(if ($fw.Count) {'OK'} else {'WARN'}) ($(if ($fw.Count) { ($fw | ForEach-Object { "$($_.DisplayName) Enabled=$($_.Enabled)" }) -join '; ' } else { 'None found (normal for desktop/localhost-only mode)' }))

# ---------------- Certificates / SSL bindings ----------------
$sslRaw = (netsh http show sslcert) -join "`n"
$bindings = @()
foreach ($block in ($sslRaw -split "`n\s*`n")) {
    $ep = [regex]::Match($block, '(IP:port|Hostname:port)\s+:\s+(\S+)').Groups[2].Value
    $hash = [regex]::Match($block, 'Certificate Hash\s+:\s+([0-9a-fA-F]+)').Groups[1].Value
    if ($ep -and $hash) { $bindings += [pscustomobject]@{ Endpoint = $ep; Hash = $hash.ToUpper() } }
}
if (-not $bindings) { Add-Result 'TLS' 'http.sys bindings' 'WARN' 'No SSL bindings found' }

function Test-NetworkServiceKeyAccess {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    try {
        $keyPath = $null
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)
        if ($rsa -is [System.Security.Cryptography.RSACng]) {
            $name = $rsa.Key.UniqueName
            $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $name
            if (-not (Test-Path $keyPath)) { $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $name }
        } elseif ($Cert.PrivateKey -and $Cert.PrivateKey.CspKeyContainerInfo) {
            $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $Cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
        }
        if (-not $keyPath -or -not (Test-Path $keyPath)) { return 'Unknown (key file not located)' }
        $acl = Get-Acl -Path $keyPath
        $hit = $acl.Access | Where-Object { $_.IdentityReference -match 'NETWORK SERVICE' -and $_.AccessControlType -eq 'Allow' }
        if ($hit) { return 'Yes' } else { return 'No' }
    } catch { return "Unknown ($($_.Exception.Message))" }
}

foreach ($b in $bindings) {
    $certItem = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $b.Hash }
    if (-not $certItem) {
        Add-Result 'TLS' "Binding $($b.Endpoint)" 'ERROR' "Bound thumbprint $($b.Hash) not found in LocalMachine\My (deleted/renewed cert?)"
        continue
    }
    $days = [int]($certItem.NotAfter - (Get-Date)).TotalDays
    $dns = @($certItem.DnsNameList | ForEach-Object { $_.Unicode })
    $eku = @($certItem.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName })
    $selfSigned = $certItem.Subject -eq $certItem.Issuer
    $nsAccess = if ($certItem.HasPrivateKey) { Test-NetworkServiceKeyAccess -Cert $certItem } else { 'No private key' }

    $status = 'OK'; $issues = @()
    if ($days -lt 0) { $status = 'ERROR'; $issues += 'EXPIRED' } elseif ($days -lt 30) { $status = 'WARN'; $issues += "expires in $days d" }
    if (-not $certItem.HasPrivateKey) { $status = 'ERROR'; $issues += 'no private key' }
    if ($eku.Count -and ($eku -notcontains 'Server Authentication')) { $status = 'ERROR'; $issues += 'no Server Authentication EKU' }
    if ($dns -notcontains $fqdn) { if ($status -eq 'OK') { $status = 'WARN' }; $issues += "gateway FQDN $fqdn not in DNS names (OK if users use an alias/HA name in the SAN)" }
    if ($selfSigned) { if ($status -eq 'OK') { $status = 'WARN' }; $issues += 'self-signed (installer certs last 60 days; not for production)' }
    if ($nsAccess -eq 'No') { $status = 'ERROR'; $issues += 'NETWORK SERVICE cannot read private key: run Set-WACCertificateAcl' }

    $detail = "Thumb=$($certItem.Thumbprint) Subject=$($certItem.Subject) NotAfter=$($certItem.NotAfter.ToString('yyyy-MM-dd')) DNS=$($dns -join ';') NetworkServiceKey=$nsAccess"
    if ($issues) { $detail += " | ISSUES: $($issues -join '; ')" }
    Add-Result 'TLS' "Binding $($b.Endpoint)" $status $detail
}

# ---------------- WAC configuration (v2 module) ----------------
$cfgModule = Join-Path $wacRoot 'PowerShellModules\Microsoft.WindowsAdminCenter.Configuration'
if (Test-Path $cfgModule) {
    try {
        Import-Module $cfgModule -ErrorAction Stop -WarningAction SilentlyContinue
        if (Get-Command Get-WACLoginMode -ErrorAction SilentlyContinue) {
            $lm = Get-WACLoginMode
            Add-Result 'Config' 'Login mode' 'INFO' ($lm | Out-String).Trim()
        }
        $ha = @(Get-Command -Module Microsoft.WindowsAdminCenter.Configuration -Name '*WACHA*' -ErrorAction SilentlyContinue)
        Add-Result 'Config' 'HA cmdlets present' 'INFO' ($ha.Count -gt 0).ToString()
    } catch {
        Add-Result 'Config' 'Configuration module' 'WARN' "Import failed: $($_.Exception.Message) (check PSModulePath order)"
    }
} elseif ($generation -like 'Modernized*') {
    Add-Result 'Config' 'Configuration module' 'WARN' "Not found at $cfgModule"
}

$cfgLog = 'C:\ProgramData\WindowsAdminCenter\Logs\Configuration.log'
if (Test-Path $cfgLog) {
    $errLines = @(Select-String -Path $cfgLog -Pattern 'error|failed|exception' -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -Last 5)
    Add-Result 'Config' 'Configuration.log errors' $(if ($errLines.Count) {'WARN'} else {'OK'}) ($(if ($errLines.Count) { ($errLines | ForEach-Object { $_.Line.Trim() }) -join ' || ' } else { 'none' }))
}

# ---------------- WinRM client side ----------------
$winrm = Get-Service WinRM -ErrorAction SilentlyContinue
Add-Result 'WinRM' 'Gateway WinRM service' $(if ($winrm -and $winrm.Status -eq 'Running') {'OK'} else {'ERROR'}) $(if ($winrm) { "$($winrm.Status)" } else { 'missing' })
try {
    $th = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
    $thStatus = if ($th -eq '*') {'WARN'} else {'INFO'}
    Add-Result 'WinRM' 'TrustedHosts' $thStatus ($(if ([string]::IsNullOrEmpty($th)) { '(empty: Kerberos-only)' } elseif ($th -eq '*') { '* (Express default; consider scoping)' } else { $th }))
} catch { Add-Result 'WinRM' 'TrustedHosts' 'WARN' "Unreadable: $($_.Exception.Message)" }
try {
    $credsspClient = (Get-Item WSMan:\localhost\Client\Auth\CredSSP -ErrorAction Stop).Value
    Add-Result 'WinRM' 'CredSSP client' 'INFO' $credsspClient
} catch { }
$credGroup = Get-LocalGroup -ErrorAction SilentlyContinue | Where-Object Name -like 'Windows Admin Center CredSSP*'
Add-Result 'WinRM' 'CredSSP admins group' 'INFO' $(if ($credGroup) { "$($credGroup.Name) members=$(@(Get-LocalGroupMember -Group $credGroup.Name -ErrorAction SilentlyContinue).Count)" } else { 'not present' })

# Browser-side HTTP/2 restriction (relevant if you browse from this host)
$httpParams = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Http\Parameters' -ErrorAction SilentlyContinue
if ($httpParams) {
    $h2 = "EnableHttp2Tls=$(if ($httpParams.PSObject.Properties['EnableHttp2Tls']) {$httpParams.EnableHttp2Tls} else {'unset'}) EnableHttp2Cleartext=$(if ($httpParams.PSObject.Properties['EnableHttp2Cleartext']) {$httpParams.EnableHttp2Cleartext} else {'unset'})"
    Add-Result 'Browser' 'HTTP/2 registry (this host)' 'INFO' $h2
}

# ---------------- Events ----------------
foreach ($logName in 'WindowsAdminCenter', 'Microsoft-ServerManagementExperience') {
    try {
        $ev = @(Get-WinEvent -LogName $logName -MaxEvents 200 -ErrorAction Stop | Where-Object { $_.Level -in 1, 2, 3 })
        $recent = @($ev | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-7) })
        $top = ($recent | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "Id $($_.Name) x$($_.Count)" }) -join '; '
        Add-Result 'Events' $logName $(if ($recent.Count) {'WARN'} else {'OK'}) "Errors/warnings last 7d: $($recent.Count) $top"
    } catch { }
}

# ---------------- Targets ----------------
foreach ($t in @($Target | Where-Object { $_ })) {
    try {
        $ip = ([System.Net.Dns]::GetHostAddresses($t) | Select-Object -First 1).IPAddressToString
        Add-Result "Target:$t" 'DNS' 'OK' $ip
    } catch { Add-Result "Target:$t" 'DNS' 'ERROR' 'Does not resolve'; continue }

    $tcp = Test-NetConnection -ComputerName $t -Port 5985 -WarningAction SilentlyContinue
    Add-Result "Target:$t" 'TCP 5985' $(if ($tcp.TcpTestSucceeded) {'OK'} else {'ERROR'}) $(if ($tcp.TcpTestSucceeded) {'open'} else {'blocked/closed: Enable-PSRemoting + firewall scope on target'})

    try { Test-WSMan -ComputerName $t -ErrorAction Stop | Out-Null; Add-Result "Target:$t" 'Test-WSMan' 'OK' 'responds' }
    catch { Add-Result "Target:$t" 'Test-WSMan' 'ERROR' $_.Exception.Message }

    if (Get-Command setspn.exe -ErrorAction SilentlyContinue) {
        $spnOut = (& setspn.exe -Q "HTTP/$t" 2>&1) -join ' '
        if ($spnOut -match 'CN=([^,]+),') {
            $owner = $Matches[1]
            $shortName = ($t -split '\.')[0]
            $st = if ($owner -ieq $shortName) {'OK'} else {'WARN'}
            Add-Result "Target:$t" 'HTTP SPN owner' $st "$owner$(if ($st -eq 'WARN') {' (not the computer account: Kerberos 0x80090322 risk; see WindowsAdminCenter-A Playbook 3)'})"
        } else {
            Add-Result "Target:$t" 'HTTP SPN owner' 'OK' 'No explicit HTTP SPN (HOST SPN applies)'
        }
    }

    if ($TestInvoke) {
        try {
            $r = Invoke-Command -ComputerName $t -ScriptBlock { "$env:COMPUTERNAME|$($PSVersionTable.PSVersion)" } -ErrorAction Stop
            Add-Result "Target:$t" 'Invoke-Command' 'OK' $r
        } catch {
            $code = if ($_.Exception.Message -match '0x[0-9a-fA-F]{8}') { $Matches[0] } else { '' }
            Add-Result "Target:$t" 'Invoke-Command' 'ERROR' "$code $($_.Exception.Message)"
        }
    }
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath "WAC-Health-$env:COMPUTERNAME-$stamp.csv"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Results: $csv" 'OK'

if ($CollectLogs) {
    $bundle = Join-Path $OutputPath "WAC-Logs-$env:COMPUTERNAME-$stamp"
    New-Item -Path $bundle -ItemType Directory -Force | Out-Null
    Copy-Item -Path 'C:\ProgramData\WindowsAdminCenter\Logs\*' -Destination $bundle -Recurse -ErrorAction SilentlyContinue
    $sslRaw | Out-File (Join-Path $bundle 'netsh-sslcert.txt')
    (netsh http show urlacl) | Out-File (Join-Path $bundle 'netsh-urlacl.txt')
    foreach ($logName in 'WindowsAdminCenter', 'Microsoft-ServerManagementExperience') {
        try {
            Get-WinEvent -LogName $logName -MaxEvents 1000 -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName, Message |
                Export-Csv (Join-Path $bundle "$logName.csv") -NoTypeInformation
        } catch { }
    }
    Copy-Item $csv $bundle
    $zip = "$bundle.zip"
    Compress-Archive -Path "$bundle\*" -DestinationPath $zip -Force
    Write-Status "Log bundle: $zip (review for sensitive data before sharing)" 'OK'
}

$errs = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Summary: $errs error(s), $warns warning(s). See WindowsAdminCenter-B.md triage table." $(if ($errs) {'ERROR'} elseif ($warns) {'WARN'} else {'OK'})
