<#
.SYNOPSIS
    Audits a Storage Spaces Direct (S2D) cluster for pool, virtual disk,
    physical disk, repair-job, and storage-network health issues.

.DESCRIPTION
    Read-only diagnostic script for the StorageSpacesDirect-A.md and
    StorageSpacesDirect-B.md runbooks. Run on any node of an S2D-enabled
    Failover Cluster with local Administrator rights.

    Covers:
      1. Cluster S2D enablement state
      2. Storage pool health, operational status, read-only reason
      3. Virtual disk health, operational status, detached reason
      4. Physical disk health per node, including cache-tier (Usage=Journal)
         drives specifically
      5. CannotPoolReason on any non-pooled eligible drive
      6. Active/stalled storage repair jobs
      7. Cluster node state
      8. Storage-network (RDMA) adapter and SMB Multichannel health
      9. Recent Storage Spaces driver event log errors

    Does NOT modify pool, virtual disk, or physical disk configuration;
    does NOT run Repair-VirtualDisk, Reset-PhysicalDisk, or any other
    remediation — findings only.

.PARAMETER StalledJobMinutes
    If a storage job's ElapsedTime exceeds this many minutes with no
    completion, it is flagged as a possible stall for manual review.
    Default: 30.

.PARAMETER OutputPath
    Folder to write CSV output to. Default: current directory.

.EXAMPLE
    .\Get-S2DHealthAudit.ps1
    Runs a standard local audit with default 30-minute stalled-job threshold.

.EXAMPLE
    .\Get-S2DHealthAudit.ps1 -StalledJobMinutes 15 -OutputPath C:\S2D-Audit
    Flags jobs running 15+ minutes, output to C:\S2D-Audit.

.NOTES
    Requires: Storage and FailoverClusters PowerShell modules (both installed
    with the Failover Clustering feature / Storage Spaces Direct role).
    Run-as: local Administrator on a cluster node.
    Safe: read-only. No pool, virtual disk, physical disk, or cluster
    configuration changes are made. Non-S2D or non-clustered hosts will
    show S2D-specific sections as NOT_APPLICABLE — expected, not an error.
#>

[CmdletBinding()]
param(
    [int]$StalledJobMinutes = 30,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[PSObject]
function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Detail)
    $findings.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Category  = $Category
        Item      = $Item
        Status    = $Status
        Detail    = $Detail
    })
    Write-Status "$Category | $Item — $Detail" -Status $Status
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

Write-Status "=== Storage Spaces Direct Health Audit ===" -Status "INFO"

#region --- Preflight: modules and cluster context ---
$hasStorage = [bool](Get-Module -ListAvailable -Name Storage -ErrorAction SilentlyContinue)
$hasCluster = [bool](Get-Module -ListAvailable -Name FailoverClusters -ErrorAction SilentlyContinue)

if (-not $hasStorage) {
    Add-Finding -Category "Preflight" -Item "Storage module" -Status "ERROR" -Detail "Storage PowerShell module not found — cannot continue"
    $findings | Export-Csv -Path (Join-Path $OutputPath "S2DHealthAudit_$(Get-Date -Format yyyyMMdd-HHmm).csv") -NoTypeInformation
    return
}
Import-Module Storage -ErrorAction SilentlyContinue

if (-not $hasCluster) {
    Add-Finding -Category "Preflight" -Item "FailoverClusters module" -Status "WARN" -Detail "Not available — cluster/network checks will be skipped (host may not be clustered)"
} else {
    Import-Module FailoverClusters -ErrorAction SilentlyContinue
}
#endregion

#region --- 1. Cluster S2D enablement ---
Write-Status "`n=== S2D Enablement ===" -Status "INFO"
$s2dEnabled = $false
if ($hasCluster) {
    try {
        $s2d = Get-ClusterS2D -ErrorAction Stop
        if ($s2d.State -eq "Enabled") {
            $s2dEnabled = $true
            Add-Finding -Category "S2D" -Item "Cluster S2D state" -Status "OK" -Detail "Enabled"
        } else {
            Add-Finding -Category "S2D" -Item "Cluster S2D state" -Status "WARN" -Detail "State: $($s2d.State) — not enabled, remaining checks may return no data"
        }
    } catch {
        Add-Finding -Category "S2D" -Item "Cluster S2D state" -Status "WARN" -Detail "Get-ClusterS2D failed — host may not be part of a cluster: $($_.Exception.Message)"
    }
} else {
    Add-Finding -Category "S2D" -Item "Cluster S2D state" -Status "WARN" -Detail "NOT_APPLICABLE — FailoverClusters module unavailable"
}
#endregion

#region --- 2. Storage pool health ---
Write-Status "`n=== Storage Pool Health ===" -Status "INFO"
try {
    $pools = Get-StoragePool -IsPrimordial $False -ErrorAction Stop
    if (-not $pools) {
        Add-Finding -Category "Pool" -Item "(none)" -Status "WARN" -Detail "No non-primordial storage pools found on this host"
    }
    foreach ($p in $pools) {
        if ($p.HealthStatus -eq "Healthy" -and -not $p.ReadOnlyReason) {
            Add-Finding -Category "Pool" -Item $p.FriendlyName -Status "OK" -Detail "HealthStatus: $($p.HealthStatus), OperationalStatus: $($p.OperationalStatus)"
        } elseif ($p.ReadOnlyReason) {
            Add-Finding -Category "Pool" -Item $p.FriendlyName -Status "ERROR" -Detail "READ-ONLY — ReadOnlyReason: $($p.ReadOnlyReason), HealthStatus: $($p.HealthStatus)"
        } else {
            Add-Finding -Category "Pool" -Item $p.FriendlyName -Status "WARN" -Detail "HealthStatus: $($p.HealthStatus), OperationalStatus: $($p.OperationalStatus)"
        }
    }
} catch {
    Add-Finding -Category "Pool" -Item "(error)" -Status "ERROR" -Detail "Get-StoragePool failed: $($_.Exception.Message)"
}
#endregion

#region --- 3. Virtual disk health ---
Write-Status "`n=== Virtual Disk Health ===" -Status "INFO"
try {
    $vdisks = Get-VirtualDisk -ErrorAction Stop
    foreach ($vd in $vdisks) {
        if ($vd.HealthStatus -eq "Healthy") {
            Add-Finding -Category "VirtualDisk" -Item $vd.FriendlyName -Status "OK" -Detail "OperationalStatus: $($vd.OperationalStatus), Resiliency: $($vd.ResiliencySettingName)"
        } elseif ($vd.HealthStatus -eq "Unhealthy") {
            Add-Finding -Category "VirtualDisk" -Item $vd.FriendlyName -Status "ERROR" -Detail "UNHEALTHY — OperationalStatus: $($vd.OperationalStatus), DetachedReason: $($vd.DetachedReason)"
        } else {
            Add-Finding -Category "VirtualDisk" -Item $vd.FriendlyName -Status "WARN" -Detail "HealthStatus: $($vd.HealthStatus), OperationalStatus: $($vd.OperationalStatus), DetachedReason: $($vd.DetachedReason)"
        }
    }
} catch {
    Add-Finding -Category "VirtualDisk" -Item "(error)" -Status "ERROR" -Detail "Get-VirtualDisk failed: $($_.Exception.Message)"
}
#endregion

#region --- 4. Physical disk health (with cache-tier flag) ---
Write-Status "`n=== Physical Disk Health ===" -Status "INFO"
try {
    $pdisks = Get-PhysicalDisk -ErrorAction Stop
    foreach ($pd in $pdisks) {
        $cacheNote = if ($pd.Usage -in @("Journal","Cache")) { " [CACHE-TIER — a fault here degrades the whole node's write performance, not just this drive]" } else { "" }
        if ($pd.HealthStatus -eq "Healthy") {
            Add-Finding -Category "PhysicalDisk" -Item $pd.FriendlyName -Status "OK" -Detail "OperationalStatus: $($pd.OperationalStatus), Usage: $($pd.Usage)$cacheNote"
        } elseif ($pd.HealthStatus -eq "Unhealthy") {
            Add-Finding -Category "PhysicalDisk" -Item $pd.FriendlyName -Status "ERROR" -Detail "UNHEALTHY — OperationalStatus: $($pd.OperationalStatus)$cacheNote"
        } else {
            Add-Finding -Category "PhysicalDisk" -Item $pd.FriendlyName -Status "WARN" -Detail "HealthStatus: $($pd.HealthStatus), OperationalStatus: $($pd.OperationalStatus)$cacheNote"
        }

        # Flag non-pooled but present drives with a CannotPoolReason (likely a
        # replacement drive waiting to be onboarded)
        if ($pd.CanPool -eq $false -and $pd.CannotPoolReason -and $pd.CannotPoolReason -ne "In a Pool") {
            Add-Finding -Category "PhysicalDisk-Pooling" -Item $pd.FriendlyName -Status "WARN" -Detail "Not pooled — CannotPoolReason: $($pd.CannotPoolReason)"
        }
    }
} catch {
    Add-Finding -Category "PhysicalDisk" -Item "(error)" -Status "ERROR" -Detail "Get-PhysicalDisk failed: $($_.Exception.Message)"
}
#endregion

#region --- 5. Storage jobs (repair/rebalance) ---
Write-Status "`n=== Storage Jobs ===" -Status "INFO"
try {
    $jobs = Get-StorageJob -ErrorAction Stop
    if (-not $jobs) {
        Add-Finding -Category "StorageJob" -Item "(none)" -Status "OK" -Detail "No active storage jobs — steady state"
    }
    foreach ($j in $jobs) {
        $elapsedMin = if ($j.ElapsedTime) { [math]::Round($j.ElapsedTime.TotalMinutes, 1) } else { 0 }
        if ($elapsedMin -ge $StalledJobMinutes -and $j.JobState -eq "Running") {
            Add-Finding -Category "StorageJob" -Item $j.Name -Status "WARN" -Detail "Running $elapsedMin min, $($j.PercentComplete)% complete — check storage network if not progressing between checks"
        } else {
            Add-Finding -Category "StorageJob" -Item $j.Name -Status "OK" -Detail "JobState: $($j.JobState), $($j.PercentComplete)% complete, elapsed $elapsedMin min"
        }
    }
} catch {
    Add-Finding -Category "StorageJob" -Item "(error)" -Status "WARN" -Detail "Get-StorageJob failed or unsupported on this host: $($_.Exception.Message)"
}
#endregion

#region --- 6. Cluster node state ---
if ($hasCluster) {
    Write-Status "`n=== Cluster Node State ===" -Status "INFO"
    try {
        $nodes = Get-ClusterNode -ErrorAction Stop
        foreach ($n in $nodes) {
            if ($n.State -eq "Up") {
                Add-Finding -Category "ClusterNode" -Item $n.Name -Status "OK" -Detail "State: Up"
            } else {
                Add-Finding -Category "ClusterNode" -Item $n.Name -Status "ERROR" -Detail "State: $($n.State) — drives owned by this node will show Lost Communication"
            }
        }
    } catch {
        Add-Finding -Category "ClusterNode" -Item "(error)" -Status "WARN" -Detail "Get-ClusterNode failed: $($_.Exception.Message)"
    }
}
#endregion

#region --- 7. Storage-network (RDMA) health ---
Write-Status "`n=== Storage Network Health ===" -Status "INFO"
if ($hasCluster) {
    try {
        $nets = Get-ClusterNetwork -ErrorAction Stop
        foreach ($net in $nets) {
            if ($net.State -eq "Up") {
                Add-Finding -Category "ClusterNetwork" -Item $net.Name -Status "OK" -Detail "State: Up, Role: $($net.Role)"
            } else {
                Add-Finding -Category "ClusterNetwork" -Item $net.Name -Status "ERROR" -Detail "State: $($net.State) — a down storage network presents as drive-level Lost Communication, not a network alert"
            }
        }
    } catch {
        Add-Finding -Category "ClusterNetwork" -Item "(error)" -Status "WARN" -Detail "Get-ClusterNetwork failed: $($_.Exception.Message)"
    }
}
try {
    $rdmaAdapters = Get-NetAdapterRdma -ErrorAction Stop
    foreach ($a in $rdmaAdapters) {
        if ($a.Enabled) {
            Add-Finding -Category "RDMA" -Item $a.Name -Status "OK" -Detail "RDMA Enabled"
        } else {
            Add-Finding -Category "RDMA" -Item $a.Name -Status "WARN" -Detail "RDMA NOT enabled on this adapter — storage traffic may fall back to non-RDMA SMB, reducing throughput"
        }
    }
} catch {
    Add-Finding -Category "RDMA" -Item "(none found)" -Status "WARN" -Detail "Get-NetAdapterRdma returned no results or is unsupported on this host's NICs"
}
#endregion

#region --- 8. Recent Storage Spaces driver event log errors ---
Write-Status "`n=== Recent Storage Spaces Driver Events ===" -Status "INFO"
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-StorageSpaces-Driver/Operational" -MaxEvents 50 -ErrorAction Stop |
        Where-Object { $_.LevelDisplayName -in "Error","Critical" }
    if ($events) {
        foreach ($e in $events) {
            Add-Finding -Category "EventLog" -Item "EventID $($e.Id)" -Status "WARN" -Detail "$($e.TimeCreated) — $($e.Message.Split("`n")[0])"
        }
    } else {
        Add-Finding -Category "EventLog" -Item "StorageSpaces-Driver" -Status "OK" -Detail "No Error/Critical events in the most recent 50 entries"
    }
} catch {
    Add-Finding -Category "EventLog" -Item "StorageSpaces-Driver" -Status "WARN" -Detail "Log unavailable or empty: $($_.Exception.Message)"
}
#endregion

#region --- Summary and export ---
$errorCount = ($findings | Where-Object Status -eq "ERROR").Count
$warnCount  = ($findings | Where-Object Status -eq "WARN").Count
Write-Status "`n=== Summary: $errorCount ERROR, $warnCount WARN out of $($findings.Count) checks ===" -Status $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

$csvPath = Join-Path $OutputPath "S2DHealthAudit_$(Get-Date -Format yyyyMMdd-HHmm).csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Findings exported to $csvPath" -Status "INFO"
#endregion
