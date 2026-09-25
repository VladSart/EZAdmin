<#
.SYNOPSIS
    Health check for Microsoft Connected Cache for Enterprise & Education — Windows cache host (WSL2) or DO client side.

.DESCRIPTION
    Host mode (run on a Windows-hosted Connected Cache node, elevated):
      - OS build vs minimum (Win11 22631.3296 / Server 2022 20348.2227), Server Core flag
      - Free RAM (>= 4 GB), free disk on install drive (>= 100 GB), active physical NIC count (must be 1)
      - WSL present / status
      - IP Helper service (required for netsh portproxy)
      - netsh portproxy v4tov4 rules for 80/443/5000 and whether they target the IP in wslIp.txt
      - Port 80 listener owner (flags ConfigMgr DP / IIS conflicts)
      - MCC_* scheduled tasks: state, last run, last result
      - Latest install/monitor transcript files in the install folder
      - Local HTTP fetch of the Microsoft test object through the node
    Client mode (run on a Windows DO client):
      - DOCacheHost / DOCacheHostSource / fallback delays from GPO and Intune (PolicyManager) locations
      - TCP 80 reachability and HTTP test-object fetch against the cache host
      - Get-DeliveryOptimizationStatus: BytesFromCacheServer vs BytesFromHttp
    Exports all checks to CSV. Read-only — changes nothing.

    Does not cover: Linux-hosted nodes (use `sudo iotedge list` / `iotedge check`), in-container diagnostics
    (use collectmccdiagnostics.sh), Azure resource configuration.

.PARAMETER Mode
    Host or Client. Default: Host.

.PARAMETER CacheHost
    Client mode: node FQDN/IP to test. If omitted, the configured DOCacheHost value is used.
    Host mode: address used for the local HTTP test (default: this machine's primary IPv4).

.PARAMETER OutputPath
    Folder for the CSV report. Default: C:\Temp

.EXAMPLE
    .\Get-ConnectedCacheNodeHealth.ps1 -Mode Host
    Checks the local Windows cache host.

.EXAMPLE
    .\Get-ConnectedCacheNodeHealth.ps1 -Mode Client -CacheHost mcc01.contoso.local
    Checks a client's targeting of and reachability to mcc01.

.NOTES
    Requires: Windows PowerShell 5.1+. Host mode must run elevated. Client mode works unelevated
    (Get-DeliveryOptimizationStatus may return less detail).
    Safe: read-only.
    Reference: https://learn.microsoft.com/windows/deployment/do/mcc-ent-troubleshooting
#>
[CmdletBinding()]
param(
    [ValidateSet('Host','Client')][string]$Mode = 'Host',
    [string]$CacheHost,
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
    param([string]$Check, [string]$Value, [string]$Status, [string]$Note = '')
    $results.Add([pscustomobject]@{ Computer=$env:COMPUTERNAME; Mode=$Mode; Check=$Check; Value=$Value; Status=$Status; Note=$Note; Timestamp=(Get-Date).ToString('s') })
    Write-Status ("{0} : {1}{2}" -f $Check, $Value, $(if ($Note) { " - $Note" } else { '' })) $Status
}
function Get-Prop { param($Obj, [string]$Name) if ($Obj -and $Obj.PSObject.Properties[$Name]) { $Obj.$Name } else { $null } }

$TestPath = '/filestreamingservice/files/7bc846e0-af9c-49be-a03d-bb04428c9bb5/Microsoft.png?cacheHostOrigin=dl.delivery.mp.microsoft.com'
function Test-CacheFetch {
    param([string]$Target)
    $url = "http://$Target$TestPath"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
        Add-Result 'HttpTestObject' "HTTP $($r.StatusCode) from $Target" $(if ($r.StatusCode -eq 200) {'OK'} else {'WARN'})
    } catch {
        Add-Result 'HttpTestObject' "Failed from $Target" 'ERROR' $_.Exception.Message
    }
}

# ---------------- Preflight ----------------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Mode -eq 'Host' -and -not $isAdmin) { Write-Status 'Host mode must be run elevated.' 'ERROR'; return }
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
$ubr = [int](Get-Prop $cv 'UBR')
Add-Result 'OSBuild' "$($cv.ProductName) $build.$ubr" 'INFO'

if ($Mode -eq 'Host') {
    # ---------------- Detect: host prerequisites ----------------
    $installType = [string](Get-Prop $cv 'InstallationType')
    $minOk = $false; $note = ''
    if ($installType -eq 'Server Core') { $note = 'Server Core is not supported by the MCC Windows installer' }
    elseif ($build -eq 22631) { $minOk = ($ubr -ge 3296); $note = 'Win11 23H2 needs >= 22631.3296' }
    elseif ($build -eq 20348) { $minOk = ($ubr -ge 2227); $note = 'Server 2022 needs >= 20348.2227' }
    elseif ($build -gt 22631 -or ($build -gt 20348 -and $installType -eq 'Server')) { $minOk = $true }
    else { $note = 'Unsupported host OS (need Windows 11 or Server 2022+)' }
    Add-Result 'HostOSSupported' "$installType $build.$ubr" $(if ($minOk) {'OK'} else {'ERROR'}) $note

    $os = Get-CimInstance Win32_OperatingSystem
    $freeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Add-Result 'FreeMemoryGB' $freeRamGB $(if ($freeRamGB -ge 4) {'OK'} else {'WARN'}) 'Minimum 4 GB free'

    $inst = [Environment]::GetEnvironmentVariable('MCC_INSTALLATION_FOLDER', 'Machine')
    if (-not $inst) { $inst = 'C:\mccwsl01'; Add-Result 'InstallFolder' $inst 'WARN' 'MCC_INSTALLATION_FOLDER not set - assuming default (not installed?)' }
    else { Add-Result 'InstallFolder' $inst 'OK' }
    $drive = $inst.Substring(0,1)
    $vol = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
    if ($vol) {
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
        Add-Result "FreeDiskGB_$drive" $freeGB $(if ($freeGB -ge 100) {'OK'} else {'WARN'}) 'Install requires >= 100 GB free'
    }

    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    Add-Result 'ActivePhysicalNICs' $nics.Count $(if ($nics.Count -eq 1) {'OK'} else {'WARN'}) 'Multiple NICs on one MCC host are not supported'

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        $wslStatus = (& wsl.exe --status 2>&1 | Out-String) -replace "`0", ''
        Add-Result 'WSL' 'Present' 'OK' (($wslStatus -split "`r?`n" | Where-Object { $_ -match 'Default Version|Kernel' }) -join '; ')
    } else { Add-Result 'WSL' 'Not found' 'ERROR' 'Install WSL2: wsl.exe --install --no-distribution' }

    $cli = Get-Command deliveryoptimization-cli -ErrorAction SilentlyContinue
    if ($cli) {
        try { $sp = (& deliveryoptimization-cli mcc-get-scripts-path 2>&1 | Out-String).Trim(); Add-Result 'ScriptsPath' $sp 'OK' }
        catch { Add-Result 'ScriptsPath' 'deliveryoptimization-cli error' 'WARN' $_.Exception.Message }
    } else { Add-Result 'ScriptsPath' 'deliveryoptimization-cli not found' 'INFO' 'Preview-package install or app not installed' }

    # ---------------- Detect: bridge ----------------
    $iph = Get-Service iphlpsvc -ErrorAction SilentlyContinue
    if ($iph) { Add-Result 'IPHelper' "$($iph.Status)/$($iph.StartType)" $(if ($iph.Status -eq 'Running') {'OK'} else {'ERROR'}) 'Required for netsh portproxy to WSL' }
    else { Add-Result 'IPHelper' 'Service missing' 'ERROR' }

    $wslIp = $null
    $ipFile = Join-Path $inst 'wslIp.txt'
    if (Test-Path $ipFile) { $wslIp = (Get-Content $ipFile | Select-Object -First 1).Trim(); Add-Result 'WslIpFile' $wslIp 'INFO' }
    else { Add-Result 'WslIpFile' 'Missing' 'WARN' $ipFile }

    $pp = (& netsh interface portproxy show v4tov4 2>&1 | Out-String) -split "`r?`n"
    foreach ($port in 80, 443, 5000) {
        $line = $pp | Where-Object { $_ -match "^\s*\S+\s+$port\s+(\S+)\s+(\d+)" } | Select-Object -First 1
        if ($line) {
            $null = $line -match "^\s*\S+\s+$port\s+(\S+)\s+(\d+)"
            $target = $Matches[1]
            $st = if ($wslIp -and $target -ne $wslIp) {'WARN'} else {'OK'}
            Add-Result "PortProxy_$port" "-> $target`:$($Matches[2])" $st $(if ($st -eq 'WARN') {"Target differs from wslIp.txt ($wslIp)"})
        } else {
            Add-Result "PortProxy_$port" 'No rule' $(if ($port -eq 80) {'ERROR'} else {'INFO'}) $(if ($port -eq 80) {'LAN clients cannot reach the container'} else {'Only needed for HTTPS (443) / remote summary page (5000)'})
        }
    }

    $l80 = @(Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue)
    foreach ($l in $l80) {
        $pn = try { (Get-Process -Id $l.OwningProcess -ErrorAction Stop).ProcessName } catch { "PID $($l.OwningProcess)" }
        $bad = $pn -match '^(w3wp|inetinfo|smsexec|ccmexec)$'
        Add-Result 'Port80Listener' "$($l.LocalAddress) $pn" $(if ($bad) {'ERROR'} else {'INFO'}) $(if ($bad) {'Port 80 conflict (IIS/ConfigMgr) - unsupported'})
    }
    if ($l80.Count -eq 0) { Add-Result 'Port80Listener' 'None' 'WARN' 'Nothing listening on 80 - portproxy/IP Helper not active' }

    $fw = @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq '80' } |
            Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
    Add-Result 'FirewallInbound80' $(if ($fw.Count) { ($fw.DisplayName -join '; ') } else { 'No enabled allow rule' }) $(if ($fw.Count) {'OK'} else {'WARN'})

    # ---------------- Detect: tasks + logs ----------------
    $tasks = @(Get-ScheduledTask -TaskName 'MCC_*' -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) { Add-Result 'ScheduledTasks' 'No MCC_* tasks' 'ERROR' 'Install incomplete or task registration blocked (GPO / batch logon right)' }
    foreach ($t in $tasks) {
        $i = $t | Get-ScheduledTaskInfo
        $ok = ($i.LastTaskResult -eq 0)
        $stale = ($t.TaskName -eq 'MCC_Monitor_Task') -and ($i.LastRunTime -lt (Get-Date).AddDays(-1))
        $st = if (-not $ok -or $stale) {'WARN'} else {'OK'}
        Add-Result "Task_$($t.TaskName)" ("State={0} LastRun={1:s} Result=0x{2:X}" -f $t.State, $i.LastRunTime, $i.LastTaskResult) $st $(if ($stale) {'Monitor task not run in 24h - check runtime account credentials'})
    }
    if (Test-Path $inst) {
        foreach ($pattern in 'WSL_Mcc_Install_FromRegisteredTask_Transcript*', 'WSL_Mcc_Monitor_FromRegisteredTask_Transcript*') {
            $f = Get-ChildItem -Path $inst -Filter $pattern -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($f) {
                $errs = @(Select-String -Path $f.FullName -Pattern 'error|fail|exception' -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -Last 3)
                Add-Result "Log_$($pattern.TrimEnd('*'))" $f.LastWriteTime.ToString('s') $(if ($errs.Count) {'WARN'} else {'OK'}) (($errs | ForEach-Object { $_.Line.Trim() }) -join ' | ')
            }
        }
    }

    # ---------------- Validate ----------------
    if (-not $CacheHost) {
        $CacheHost = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                      Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|WSL|Loopback' } |
                      Select-Object -First 1 -ExpandProperty IPAddress)
    }
    if ($CacheHost) { Test-CacheFetch -Target $CacheHost } else { Add-Result 'HttpTestObject' 'Skipped' 'WARN' 'No host IPv4 found' }
}
else {
    # ---------------- Client mode ----------------
    $gpo = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue
    $mdm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization' -ErrorAction SilentlyContinue
    $cfgHost = @((Get-Prop $mdm 'DOCacheHost'), (Get-Prop $gpo 'DOCacheHost')) | Where-Object { $_ } | Select-Object -First 1
    $src     = @((Get-Prop $mdm 'DOCacheHostSource'), (Get-Prop $gpo 'DOCacheHostSource')) | Where-Object { $_ -ne $null } | Select-Object -First 1
    Add-Result 'DOCacheHost' $(if ($cfgHost) { $cfgHost } else { 'Not set' }) $(if ($cfgHost -or $src) {'OK'} else {'WARN'}) $(if (-not $cfgHost -and -not $src) {'Client is not pointed at any cache node'})
    Add-Result 'DOCacheHostSource' $(if ($src -ne $null) { "$src (1=DHCP 235, 2=DHCP 235 force)" } else { 'Not set' }) 'INFO'
    foreach ($n in 'DODelayCacheServerFallbackForeground','DODelayCacheServerFallbackBackground') {
        $v = @((Get-Prop $mdm $n), (Get-Prop $gpo $n)) | Where-Object { $_ -ne $null } | Select-Object -First 1
        if ($v -ne $null) { Add-Result $n "$v s" 'INFO' }
    }
    $dm = @((Get-Prop $mdm 'DODownloadMode'), (Get-Prop $gpo 'DODownloadMode')) | Where-Object { $_ -ne $null } | Select-Object -First 1
    if ($dm -ne $null) { Add-Result 'DODownloadMode' $dm $(if ([int]$dm -eq 100) {'ERROR'} else {'INFO'}) $(if ([int]$dm -eq 100) {'Bypass mode (100) skips Delivery Optimization entirely'}) }

    if (-not $CacheHost -and $cfgHost) { $CacheHost = ($cfgHost -split ',')[0].Trim() }
    if ($CacheHost) {
        try {
            $tnc = Test-NetConnection -ComputerName $CacheHost -Port 80 -WarningAction SilentlyContinue
            Add-Result 'TCP80ToNode' "$CacheHost = $($tnc.TcpTestSucceeded)" $(if ($tnc.TcpTestSucceeded) {'OK'} else {'ERROR'})
        } catch { Add-Result 'TCP80ToNode' 'Test failed' 'WARN' $_.Exception.Message }
        Test-CacheFetch -Target $CacheHost
    } else { Add-Result 'CacheHostTest' 'Skipped' 'WARN' 'No -CacheHost and no DOCacheHost configured' }

    try {
        $jobs = @(Get-DeliveryOptimizationStatus -ErrorAction Stop)
        $cache = ($jobs | Measure-Object -Property BytesFromCacheServer -Sum).Sum
        $http  = ($jobs | Measure-Object -Property BytesFromHttp -Sum).Sum
        if ($null -eq $cache) { $cache = 0 }; if ($null -eq $http) { $http = 0 }
        Add-Result 'DOJobs' $jobs.Count 'INFO'
        Add-Result 'BytesFromCacheServer' ("{0:N1} MB" -f ($cache/1MB)) $(if ($cache -gt 0) {'OK'} elseif ($jobs.Count) {'WARN'} else {'INFO'}) $(if ($cache -eq 0 -and $jobs.Count) {'Recent downloads did not use the cache node'})
        Add-Result 'BytesFromHttp' ("{0:N1} MB" -f ($http/1MB)) 'INFO'
    } catch { Add-Result 'DOStatus' 'Get-DeliveryOptimizationStatus failed' 'WARN' $_.Exception.Message }
}

# ---------------- Report ----------------
$errCount  = @($results | Where-Object Status -eq 'ERROR').Count
$warnCount = @($results | Where-Object Status -eq 'WARN').Count
Add-Result 'Summary' "Errors=$errCount Warnings=$warnCount" $(if ($errCount) {'ERROR'} elseif ($warnCount) {'WARN'} else {'OK'})
$csv = Join-Path $OutputPath ("ConnectedCacheHealth_{0}_{1}_{2}.csv" -f $Mode, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Status "Report written: $csv" 'OK'
