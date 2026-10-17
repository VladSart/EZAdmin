<#
.SYNOPSIS
    Read-only health check for SQL Server Failover Cluster Instances (FCI) on a Windows Server Failover Cluster.

.DESCRIPTION
    Run on any node of the cluster. For every SQL Server FCI role (or the one named with -RoleName) it reports:
      - Role state, owner node, failover threshold/period and auto-failback setting
      - Each resource in the role (IP, Network Name, Distributed Network Name, disks, SQL Server, SQL Server Agent):
        state, owner, dependency expression and possible owners
      - Whether the SQL Server resource depends on every non-CSV Physical Disk in the role (flags missing dependencies)
      - Whether possible owners are consistent across SQL / name / disk / DNN resources
      - SQL Server resource private properties (VirtualServerName, InstanceName, HealthCheckTimeout, FailureConditionLevel)
      - SQL build (PatchLevel) per possible-owner node via remote registry over WinRM (skip with -SkipRemote)
      - Optional DNS resolution and TCP test of each VNN/DNN name (-TestConnectivity)
      - FailoverClustering events 1069/1205/1254/1230 from the last -EventHours hours
    Results are written to the console and exported to CSV.

    Does NOT: change any cluster or SQL setting, connect to SQL Server, read the SQL errorlog, check AG listeners
    (use Get-SQLAGListenerHealth.ps1) or diagnose quorum/node health.

.PARAMETER RoleName
    Name of the FCI cluster group, e.g. 'SQL Server (MSSQLSERVER)'. Default: all groups containing a 'SQL Server' resource.

.PARAMETER TestConnectivity
    Resolve each VNN/DNN DNS name and test TCP to -Port on each returned address.

.PARAMETER Port
    TCP port used with -TestConnectivity. Default 1433.

.PARAMETER SkipRemote
    Do not query other nodes for the SQL build (no WinRM needed).

.PARAMETER EventHours
    How many hours of cluster events to read. Default 24.

.PARAMETER OutputPath
    Folder for the CSV report. Default: C:\Temp

.EXAMPLE
    .\Get-SQLFCIHealth.ps1
    Checks every FCI on the cluster and writes C:\Temp\SQLFCIHealth-<timestamp>.csv

.EXAMPLE
    .\Get-SQLFCIHealth.ps1 -RoleName 'SQL Server (PROD01)' -TestConnectivity -Port 50100 -EventHours 72

.NOTES
    Requires: Windows PowerShell 5.1+, FailoverClusters module (Failover Clustering feature or RSAT), run on a cluster node.
    Run as: local administrator (cluster read access). Remote build check needs WinRM to the other nodes.
    Safe: read-only. No cluster, registry or SQL changes are made.
#>
#Requires -Modules FailoverClusters
[CmdletBinding()]
param(
    [string]$RoleName,
    [switch]$TestConnectivity,
    [int]$Port = 1433,
    [switch]$SkipRemote,
    [int]$EventHours = 24,
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
    param([string]$Role, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Role = $Role; Check = $Check; Status = $Status; Detail = $Detail })
    Write-Status -Message ("{0} | {1}: {2}" -f $Role, $Check, $Detail) -Status $Status
}

function Get-ParamValue {
    param($Resource, [string]$Name)
    try {
        $p = $Resource | Get-ClusterParameter -Name $Name -ErrorAction Stop
        return $p.Value
    } catch { return $null }
}

# ---------------- Preflight ----------------
try {
    $cluster = Get-Cluster
} catch {
    Write-Status "Not a cluster node or cluster service unavailable: $($_.Exception.Message)" 'ERROR'
    return
}
Write-Status "Cluster: $($cluster.Name)"
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$nodes = @(Get-ClusterNode)
foreach ($n in $nodes) {
    $st = if ($n.State -eq 'Up') { 'OK' } else { 'WARN' }
    Add-Result -Role '(cluster)' -Check "Node $($n.Name)" -Status $st -Detail "State=$($n.State)"
}

# ---------------- Detect FCI roles ----------------
$sqlResources = @(Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'SQL Server' })
if ($RoleName) { $sqlResources = @($sqlResources | Where-Object { $_.OwnerGroup.Name -eq $RoleName }) }
if ($sqlResources.Count -eq 0) {
    Write-Status 'No SQL Server FCI resources found (AG-only clusters have none - use Get-SQLAGListenerHealth.ps1).' 'WARN'
    return
}

$csvNames = @()
try { $csvNames = @(Get-ClusterSharedVolume -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { $csvNames = @() }

# ---------------- Execute per FCI ----------------
foreach ($sqlRes in $sqlResources) {
    $group = $sqlRes.OwnerGroup
    $g = Get-ClusterGroup -Name $group.Name
    $role = $g.Name

    $gState = if ($g.State -eq 'Online') { 'OK' } elseif ($g.State -eq 'Failed') { 'ERROR' } else { 'WARN' }
    Add-Result $role 'Role state' $gState "State=$($g.State); Owner=$($g.OwnerNode)"
    $thr = if ($g.FailoverThreshold -eq 4294967295) { 'default (nodes-1)' } else { [string]$g.FailoverThreshold }
    Add-Result $role 'Failover policy' 'INFO' "Threshold=$thr; PeriodHours=$($g.FailoverPeriod); AutoFailbackType=$($g.AutoFailbackType)"

    $members = @($g | Get-ClusterResource)
    $ownerSets = @{}
    foreach ($r in $members) {
        $type = $r.ResourceType.Name
        $dep = ''
        try { $dep = (Get-ClusterResourceDependency -Resource $r.Name).DependencyExpression } catch { $dep = '(unreadable)' }
        $owners = @()
        try { $owners = @(($r | Get-ClusterOwnerNode).OwnerNodes | ForEach-Object { $_.Name } | Sort-Object) } catch { $owners = @() }
        $ownerSets[$r.Name] = ($owners -join ',')
        $st = if ($r.State -eq 'Online') { 'OK' } elseif ($r.State -eq 'Failed') { 'ERROR' } else { 'WARN' }
        Add-Result $role "Resource [$type] $($r.Name)" $st "State=$($r.State); Dep=$dep; PossibleOwners=$($owners -join ',')"
    }

    # SQL resource private properties
    $vsn  = Get-ParamValue $sqlRes 'VirtualServerName'
    $inst = Get-ParamValue $sqlRes 'InstanceName'
    $hct  = Get-ParamValue $sqlRes 'HealthCheckTimeout'
    $fcl  = Get-ParamValue $sqlRes 'FailureConditionLevel'
    Add-Result $role 'SQL resource properties' 'INFO' "VirtualServerName=$vsn; InstanceName=$inst; HealthCheckTimeout=$hct; FailureConditionLevel=$fcl"
    if ($null -ne $hct -and [int]$hct -ne 60000) { Add-Result $role 'HealthCheckTimeout' 'WARN' "Non-default ($hct ms). Confirm it was a deliberate, documented change." }
    if ($null -ne $fcl -and [int]$fcl -ne 3)     { Add-Result $role 'FailureConditionLevel' 'WARN' "Non-default ($fcl). Default is 3." }

    # Disk dependency completeness
    $sqlDep = ''
    try { $sqlDep = [string](Get-ClusterResourceDependency -Resource $sqlRes.Name).DependencyExpression } catch { $sqlDep = '' }
    $disks = @($members | Where-Object { $_.ResourceType.Name -eq 'Physical Disk' })
    if ($disks.Count -eq 0) {
        $note = if ($csvNames.Count -gt 0) { "No Physical Disk resources in role; cluster has $($csvNames.Count) CSV(s) - CSV/SMB storage needs no dependency." } else { 'No Physical Disk resources in role (SMB or CSV storage?).' }
        Add-Result $role 'Disk dependencies' 'INFO' $note
    } else {
        foreach ($d in $disks) {
            if ($sqlDep.Contains("[$($d.Name)]")) {   # .Contains, not -like: [ ] are wildcard characters
                Add-Result $role "Dependency on $($d.Name)" 'OK' 'SQL Server resource depends on this disk'
            } else {
                Add-Result $role "Dependency on $($d.Name)" 'WARN' 'Disk is in the role but NOT in the SQL dependency - databases on it will be refused (error 5184) or start before the disk'
            }
        }
    }

    # Network name presence and possible-owner consistency
    $vnn = @($members | Where-Object { $_.ResourceType.Name -eq 'Network Name' })
    $dnn = @($members | Where-Object { $_.ResourceType.Name -eq 'Distributed Network Name' })
    if ($vnn.Count -eq 0) { Add-Result $role 'VNN' 'ERROR' 'No Network Name resource in role - the FCI VNN must exist (do not delete it even when using a DNN)' }
    if ($dnn.Count -gt 0) { Add-Result $role 'DNN' 'INFO' "DNN present ($($dnn[0].Name)). Clients must use MultiSubnetFailover=True." }

    $sqlOwners = $ownerSets[$sqlRes.Name]
    foreach ($r in $members) {
        if ($r.ResourceType.Name -in @('Network Name','Distributed Network Name','Physical Disk')) {
            if ($ownerSets[$r.Name] -ne $sqlOwners) {
                Add-Result $role "Owner consistency $($r.Name)" 'WARN' "PossibleOwners '$($ownerSets[$r.Name])' differ from SQL resource '$sqlOwners'"
            }
        }
    }

    # SQL build per possible-owner node
    if (-not $SkipRemote -and $inst) {
        $builds = @{}
        foreach ($nodeName in ($sqlOwners -split ',' | Where-Object { $_ })) {
            try {
                $b = Invoke-Command -ComputerName $nodeName -ErrorAction Stop -ArgumentList $inst -ScriptBlock {
                    param($InstanceName)
                    $map = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
                    if (-not $map) { return 'NOT INSTALLED' }
                    $id = $map.$InstanceName
                    if (-not $id) { return 'NOT INSTALLED' }
                    $setup = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\Setup" -ErrorAction SilentlyContinue
                    if ($setup -and ($setup.PSObject.Properties.Name -contains 'PatchLevel')) { return [string]$setup.PatchLevel }
                    return 'UNKNOWN'
                }
                $builds[$nodeName] = [string]$b
            } catch {
                $builds[$nodeName] = "unreachable ($($_.Exception.Message.Split([Environment]::NewLine)[0]))"
            }
        }
        $distinct = @($builds.Values | Where-Object { $_ -notlike 'unreachable*' } | Sort-Object -Unique)
        $detail = ($builds.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
        $bs = if ($builds.Values -contains 'NOT INSTALLED') { 'ERROR' } elseif ($distinct.Count -gt 1) { 'WARN' } else { 'OK' }
        Add-Result $role 'SQL build per node' $bs $detail
    }

    # Connectivity
    if ($TestConnectivity) {
        $names = @()
        foreach ($r in ($vnn + $dnn)) { $dn = Get-ParamValue $r 'DnsName'; if ($dn) { $names += $dn } }
        foreach ($nm in ($names | Sort-Object -Unique)) {
            try {
                $ips = @(Resolve-DnsName -Name $nm -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
                Add-Result $role "DNS $nm" 'OK' ("Resolves to " + ($ips -join ', '))
                foreach ($ip in $ips) {
                    $ok = (Test-NetConnection -ComputerName $ip -Port $Port -WarningAction SilentlyContinue).TcpTestSucceeded
                    $s = if ($ok) { 'OK' } else { 'INFO' }
                    Add-Result $role "TCP ${ip}:$Port" $s ("Open=$ok" + $(if ($dnn.Count -gt 0 -and -not $ok) { ' (expected on non-owner nodes for a DNN)' } else { '' }))
                }
            } catch {
                Add-Result $role "DNS $nm" 'ERROR' "Resolution failed: $($_.Exception.Message)"
            }
        }
    }
}

# ---------------- Events ----------------
try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-FailoverClustering'; Id = 1069,1205,1254,1230; StartTime = (Get-Date).AddHours(-$EventHours) } -ErrorAction Stop)
    $sum = $ev | Group-Object Id | ForEach-Object { "$($_.Name)x$($_.Count)" }
    Add-Result '(cluster)' "Events last ${EventHours}h" 'WARN' ($sum -join ', ')
    $ev | Select-Object -First 5 | ForEach-Object {
        $msg = ($_.Message -replace '\s+', ' ')
        if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) }
        Add-Result '(cluster)' "Event $($_.Id) $($_.TimeCreated.ToString('s'))" 'INFO' $msg
    }
} catch {
    Add-Result '(cluster)' "Events last ${EventHours}h" 'OK' 'No 1069/1205/1254/1230 events found'
}

# ---------------- Report ----------------
$file = Join-Path $OutputPath ("SQLFCIHealth-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$results | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
$errs  = @($results | Where-Object Status -eq 'ERROR').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count
Write-Status "Done. $errs error(s), $warns warning(s). Report: $file" $(if ($errs) { 'ERROR' } elseif ($warns) { 'WARN' } else { 'OK' })
