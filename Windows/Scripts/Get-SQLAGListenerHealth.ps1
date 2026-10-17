<#
.SYNOPSIS
    Read-only health audit of SQL Server Always On availability group listeners (cluster, DNS and port layers).

.DESCRIPTION
    Run on a WSFC node that hosts an availability group. For every AG cluster role (or the one named in
    -ClusterGroup) it reports:
      - Each listener Network Name / Distributed Network Name resource: state, DnsName,
        RegisterAllProvidersIP, HostRecordTTL, dependency expression (OR vs AND)
      - Each listener IP Address resource: address, mask, state, and whether a cluster network with a
        client-capable role exists for that subnet
      - DNS: the A records returned for the listener (optionally against specific DNS servers) and the TTL
      - TCP reachability of the listener port on every returned IP (optional, -Port)
    It then flags the classic multi-subnet problems: RAPI=1 with multiple A records (clients need
    MultiSubnetFailover), RAPI=0 with a long TTL, AND dependency, IP resources in Failed state, missing
    cluster networks, more than one IP online, and DNS records that don't match the online IP.

    Does NOT change anything. Does NOT query SQL Server (no SQL module dependency). Does NOT inspect client
    connection strings. Use SQLAGListener-A.md for those layers.

.PARAMETER ClusterGroup
    Optional. Name of the AG cluster role (equals the AG name). Default: every group that contains a
    'SQL Server Availability Group' resource.

.PARAMETER ListenerFqdn
    Optional. FQDN to resolve. Default: <DnsName>.<cluster domain> for each listener.

.PARAMETER Port
    Optional. Listener TCP port to test on every returned IP. Skipped if not supplied.

.PARAMETER DnsServer
    Optional. One or more DNS servers to query (compare answers across sites). Default: the local resolver.

.PARAMETER MaxTtlSeconds
    TTL above which a RAPI=0 listener is flagged. Default 300.

.PARAMETER OutputPath
    Folder for the CSV report. Default: current directory.

.EXAMPLE
    .\Get-SQLAGListenerHealth.ps1
    Audit every AG listener on this cluster using the local resolver.

.EXAMPLE
    .\Get-SQLAGListenerHealth.ps1 -ClusterGroup 'AG-Sales' -Port 1433 -DnsServer 'dc01.contoso.com','dc11.contoso.com' -OutputPath C:\Temp
    Audit one AG, compare DNS answers from two sites and test port 1433 on each returned IP.

.NOTES
    Requires: Windows PowerShell 5.1+, FailoverClusters module, DnsClient module. Run on a cluster node
    (local admin). Read-only and safe to run in production. Port tests against offline-subnet IPs will
    take a few seconds each to time out. That is expected.
#>
[CmdletBinding()]
param(
    [string]$ClusterGroup,
    [string]$ListenerFqdn,
    [int]$Port,
    [string[]]$DnsServer,
    [int]$MaxTtlSeconds = 300,
    [string]$OutputPath = (Get-Location).Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-ParamValue {
    param($Resource, [string]$Name)
    try {
        $p = $Resource | Get-ClusterParameter -Name $Name -ErrorAction Stop
        return $p.Value
    } catch { return $null }
}

function Test-SameSubnet {
    param([string]$Ip, [string]$NetAddress, [string]$Mask)
    try {
        $a = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
        $n = ([System.Net.IPAddress]::Parse($NetAddress)).GetAddressBytes()
        $m = ([System.Net.IPAddress]::Parse($Mask)).GetAddressBytes()
        if ($a.Length -ne $m.Length -or $n.Length -ne $m.Length) { return $false }
        for ($i = 0; $i -lt $m.Length; $i++) {
            if (($a[$i] -band $m[$i]) -ne ($n[$i] -band $m[$i])) { return $false }
        }
        return $true
    } catch { return $false }
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Group, [string]$Listener, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('s'); ClusterGroup = $Group; Listener = $Listener
        Check = $Check; Status = $Status; Detail = $Detail
    })
    Write-Status "$Group / $Listener : $Check - $Detail" $Status
}

# ---------------- Preflight ----------------
foreach ($m in 'FailoverClusters','DnsClient') {
    if (-not (Get-Module -ListAvailable -Name $m)) { Write-Status "Module '$m' not available. Run on a cluster node with RSAT clustering." "ERROR"; exit 1 }
    Import-Module $m -ErrorAction Stop
}
try { $cluster = Get-Cluster -ErrorAction Stop } catch { Write-Status "Not a cluster node or cluster service unreachable: $($_.Exception.Message)" "ERROR"; exit 1 }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
Write-Status "Cluster: $($cluster.Name) (domain $($cluster.Domain))"

$networks = @(Get-ClusterNetwork)

# ---------------- Detect AG groups ----------------
$agResources = @(Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'SQL Server Availability Group' })
if ($ClusterGroup) { $agResources = @($agResources | Where-Object { $_.OwnerGroup.Name -eq $ClusterGroup }) }
if ($agResources.Count -eq 0) { Write-Status "No 'SQL Server Availability Group' resources found$(if($ClusterGroup){" in group '$ClusterGroup'"})." "WARN"; exit 0 }

foreach ($agRes in $agResources) {
    $groupName = $agRes.OwnerGroup.Name
    $groupRes  = @(Get-ClusterGroup -Name $groupName | Get-ClusterResource)
    Add-Result $groupName '-' 'AG resource' $(if ($agRes.State -eq 'Online') {'OK'} else {'ERROR'}) "State=$($agRes.State) Owner=$($agRes.OwnerNode)"

    $names = @($groupRes | Where-Object { $_.ResourceType.Name -in 'Network Name','Distributed Network Name' })
    if ($names.Count -eq 0) { Add-Result $groupName '-' 'Listener' 'WARN' 'No listener resource in this AG role (clients must use replica names)'; continue }

    $ips = @($groupRes | Where-Object { $_.ResourceType.Name -eq 'IP Address' })

    foreach ($nn in $names) {
        $isDnn   = ($nn.ResourceType.Name -eq 'Distributed Network Name')
        $dnsName = Get-ParamValue $nn 'DnsName'
        if (-not $dnsName) { $dnsName = $nn.Name }
        $label   = "$dnsName$(if($isDnn){' (DNN)'})"
        Add-Result $groupName $label 'Name resource' $(if ($nn.State -eq 'Online') {'OK'} else {'ERROR'}) "Resource '$($nn.Name)' State=$($nn.State)"

        $rapi = $null; $ttl = $null; $onlineIps = @()
        if (-not $isDnn) {
            $rapi = Get-ParamValue $nn 'RegisterAllProvidersIP'
            $ttl  = Get-ParamValue $nn 'HostRecordTTL'
            Add-Result $groupName $label 'RegisterAllProvidersIP' 'INFO' "$rapi"
            Add-Result $groupName $label 'HostRecordTTL' 'INFO' "$ttl"
            if ("$rapi" -eq '0' -and $ttl -and [int]$ttl -gt $MaxTtlSeconds) {
                Add-Result $groupName $label 'TTL vs RAPI=0' 'WARN' "RAPI=0 with TTL $ttl s: clients may wait up to $ttl s after failover. Consider <= $MaxTtlSeconds (SQLAGListener-B Fix 3)"
            }

            try {
                $dep = (Get-ClusterResourceDependency -Resource $nn.Name -ErrorAction Stop).DependencyExpression
                $st = if ($ips.Count -gt 1 -and $dep -match '\band\b' -and $dep -notmatch '\bor\b') {'ERROR'} else {'OK'}
                Add-Result $groupName $label 'Dependency expression' $st "$dep"
            } catch { Add-Result $groupName $label 'Dependency expression' 'WARN' "Could not read: $($_.Exception.Message)" }

            # IP resources
            foreach ($ipRes in $ips) {
                $addr = Get-ParamValue $ipRes 'Address'
                $mask = Get-ParamValue $ipRes 'SubnetMask'
                $st = switch ("$($ipRes.State)") { 'Online' {'OK'} 'Offline' {'INFO'} default {'ERROR'} }
                Add-Result $groupName $label "IP resource $($ipRes.Name)" $st "Address=$addr Mask=$mask State=$($ipRes.State)"
                if ("$($ipRes.State)" -eq 'Online') { $onlineIps += "$addr" }

                $net = $networks | Where-Object { $addr -and $_.Address -and (Test-SameSubnet -Ip $addr -NetAddress $_.Address -Mask $_.AddressMask) } | Select-Object -First 1
                if (-not $net) {
                    Add-Result $groupName $label "Cluster network for $addr" 'ERROR' 'No cluster network matches this subnet. Listener cannot come online on nodes there'
                } elseif ([int]$net.Role -eq 0) {
                    Add-Result $groupName $label "Cluster network for $addr" 'ERROR' "Network '$($net.Name)' Role=None. Cluster will not host client IPs on it"
                } else {
                    Add-Result $groupName $label "Cluster network for $addr" 'OK' "Network '$($net.Name)' Role=$($net.Role) State=$($net.State)"
                }
            }
            if ($onlineIps.Count -gt 1) { Add-Result $groupName $label 'Online IP count' 'WARN' "More than one listener IP online: $($onlineIps -join ', ')" }
            elseif ($onlineIps.Count -eq 0) { Add-Result $groupName $label 'Online IP count' 'ERROR' 'No listener IP online' }
        }

        # DNS
        $fqdn = if ($ListenerFqdn) { $ListenerFqdn } elseif ($dnsName -like '*.*') { $dnsName } else { "$dnsName.$($cluster.Domain)" }
        $servers = if ($DnsServer) { $DnsServer } else { @($null) }
        $allAnswerIps = @()
        foreach ($srv in $servers) {
            $srvLabel = if ($srv) { $srv } else { 'local resolver' }
            try {
                $splat = @{ Name = $fqdn; Type = 'A'; DnsOnly = $true; ErrorAction = 'Stop' }
                if ($srv) { $splat.Server = $srv }
                $ans = @(Resolve-DnsName @splat | Where-Object { $_.Type -eq 'A' })
                $ipList = @($ans | ForEach-Object { $_.IPAddress })
                $allAnswerIps += $ipList
                $ttlSeen = if ($ans.Count -gt 0) { $ans[0].TTL } else { '-' }
                Add-Result $groupName $label "DNS ($srvLabel)" 'INFO' "$fqdn -> $($ipList -join ', ') (TTL $ttlSeen)"

                if (-not $isDnn) {
                    if ("$rapi" -eq '1' -and $ipList.Count -gt 1) {
                        Add-Result $groupName $label "DNS ($srvLabel) multi-IP" 'WARN' "RAPI=1 returns $($ipList.Count) IPs. Every client MUST use MultiSubnetFailover=True or it will time out ~50% of the time (SQLAGListener-B Fix 1)"
                    }
                    if ("$rapi" -eq '0') {
                        $extra = @($ipList | Where-Object { $onlineIps -notcontains $_ })
                        if ($extra.Count -gt 0) { Add-Result $groupName $label "DNS ($srvLabel) stale" 'ERROR' "RAPI=0 but DNS returns non-online IP(s): $($extra -join ', '). Stale record or replication lag (Fix 2/3)" }
                    }
                } else {
                    Add-Result $groupName $label "DNS ($srvLabel) DNN" 'WARN' 'DNN listener: clients MUST use MultiSubnetFailover=True and the explicit DNN port'
                }
            } catch {
                Add-Result $groupName $label "DNS ($srvLabel)" 'ERROR' "Resolve failed for ${fqdn}: $($_.Exception.Message)"
            }
        }

        # Port tests
        if ($PSBoundParameters.ContainsKey('Port')) {
            foreach ($ip in ($allAnswerIps | Select-Object -Unique)) {
                $open = $false
                $tcp = New-Object System.Net.Sockets.TcpClient
                try {
                    $iar = $tcp.BeginConnect($ip, $Port, $null, $null)
                    if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) { $tcp.EndConnect($iar); $open = $true }
                } catch { $open = $false } finally { $tcp.Close() }
                $st = if ($open) {'OK'} elseif (-not $isDnn -and $onlineIps -notcontains $ip) {'INFO'} else {'ERROR'}
                $note = if (-not $open -and $st -eq 'INFO') { ' (offline-subnet IP: expected to fail)' } else { '' }
                Add-Result $groupName $label "TCP $ip`:$Port" $st "Open=$open$note"
            }
        }
    }
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath ("SQLAGListenerHealth_{0}_{1}.csv" -f $cluster.Name, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$err  = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. $err error(s), $warn warning(s). Report: $csv" $(if ($err) {'ERROR'} elseif ($warn) {'WARN'} else {'OK'})
