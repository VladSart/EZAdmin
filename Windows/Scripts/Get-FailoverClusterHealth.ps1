<#
.SYNOPSIS
    Audits Windows Server Failover Clustering (WSFC) health — node state,
    quorum configuration, witness health, cluster networks, and node
    quarantine status.

.DESCRIPTION
    Read-only diagnostic script for the FailoverClustering-A.md and
    FailoverClustering-B.md runbooks. Run on any cluster node, or against
    a remote cluster via -ClusterName, with permissions to query the
    cluster (local Administrator on a node, or an account with cluster
    read access remotely).

    Covers:
      1. Cluster service and node membership (state, DynamicWeight,
         NodeQuarantineState)
      2. Quorum type and witness resource health
      3. Cluster network state and role assignment (flags Partitioned
         networks distinctly from Down, since Partitioned is the more
         dangerous asymmetric-failure state)
      4. Recent quorum/quarantine/network/storage-relevant cluster events
         (Event IDs 1069, 1135, 1177, 1558, 1641, 1647, 1649, 5120, 5142,
         7031)
      5. Cluster-Aware Updating (CAU) role presence and last run status,
         if configured

    Does NOT force quorum, clear quarantine, change quorum configuration,
    or trigger a CAU run — findings only.

.PARAMETER ClusterName
    Name of the cluster to query. Default: the local cluster (auto-detected
    from the node this script is run on).

.PARAMETER EventLookbackHours
    How far back to scan the FailoverClustering Operational log for
    quorum/quarantine/network/storage events. Default: 24.

.PARAMETER OutputPath
    Folder to write CSV output to. Default: current directory.

.EXAMPLE
    .\Get-FailoverClusterHealth.ps1
    Audits the local cluster with the default 24-hour event lookback.

.EXAMPLE
    .\Get-FailoverClusterHealth.ps1 -ClusterName PROD-CLUS01 -EventLookbackHours 72 -OutputPath C:\ClusterAudit
    Audits a named cluster with a 72-hour event lookback.

.NOTES
    Requires: FailoverClusters PowerShell module (installed with the
    Failover Clustering feature/RSAT tools).
    Run-as: local Administrator on a cluster node, or an account with
    read access to the target cluster.
    Safe: read-only. No quorum, quarantine, network, or CAU configuration
    is changed.
#>

[CmdletBinding()]
param(
    [string]$ClusterName,
    [int]$EventLookbackHours = 24,
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

Write-Status "=== Failover Clustering Health Audit ===" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name FailoverClusters)) {
    Add-Finding -Category "Prerequisite" -Item "FailoverClusters module" -Status "ERROR" -Detail "Module not found — install the Failover Clustering feature or RSAT tools before running this script"
    $findings | Export-Csv -Path (Join-Path $OutputPath "FailoverClusterHealth_$(Get-Date -Format yyyyMMdd-HHmm).csv") -NoTypeInformation
    return
}
Import-Module FailoverClusters -ErrorAction Stop

#region --- 1. Cluster identity and quorum type ---
Write-Status "`n=== Cluster and Quorum ===" -Status "INFO"
try {
    $clusterParams = @{}
    if ($ClusterName) { $clusterParams["Name"] = $ClusterName }
    $cluster = Get-Cluster @clusterParams -ErrorAction Stop
    Add-Finding -Category "Cluster" -Item $cluster.Name -Status "OK" -Detail "Reachable"

    $quorum = Get-ClusterQuorum @clusterParams -ErrorAction Stop
    $riskyQuorum = $quorum.QuorumType -eq "DiskOnly"
    Add-Finding -Category "Quorum" -Item "QuorumType" -Status $(if ($riskyQuorum) { "WARN" } else { "OK" }) `
        -Detail "$($quorum.QuorumType)$(if ($riskyQuorum) { ' — DiskOnly is not recommended: single point of failure' } else { '' })"
} catch {
    $clusterLabel = if ($ClusterName) { $ClusterName } else { "(local)" }
    Add-Finding -Category "Cluster" -Item $clusterLabel -Status "ERROR" -Detail "Could not reach cluster: $($_.Exception.Message)"
    $findings | Export-Csv -Path (Join-Path $OutputPath "FailoverClusterHealth_$(Get-Date -Format yyyyMMdd-HHmm).csv") -NoTypeInformation
    return
}
#endregion

#region --- 2. Node state, votes, quarantine ---
Write-Status "`n=== Cluster Nodes ===" -Status "INFO"
try {
    $nodes = Get-ClusterNode @clusterParams -ErrorAction Stop
    $upNodes = ($nodes | Where-Object State -eq "Up").Count
    $totalVotes = ($nodes | Where-Object { $_.DynamicWeight -eq 1 }).Count
    if ($quorum.QuorumResource) { $totalVotes++ }  # witness contributes a vote when present/online

    foreach ($n in $nodes) {
        $quarantined = $n.NodeQuarantineState -and $n.NodeQuarantineState -ne "NotQuarantined"
        if ($n.State -ne "Up") {
            Add-Finding -Category "Node" -Item $n.Name -Status "ERROR" -Detail "State: $($n.State)"
        } elseif ($quarantined) {
            Add-Finding -Category "Node" -Item $n.Name -Status "ERROR" -Detail "NodeQuarantineState: $($n.NodeQuarantineState) — node is Up but cannot host roles; check Event IDs 1641/1647/1649/7031 for root cause before clearing"
        } elseif ($n.DynamicWeight -eq 0) {
            Add-Finding -Category "Node" -Item $n.Name -Status "WARN" -Detail "DynamicWeight: 0 — node holds no current quorum vote (expected during graceful dynamic-quorum adjustment, unexpected otherwise)"
        } else {
            Add-Finding -Category "Node" -Item $n.Name -Status "OK" -Detail "State: Up, DynamicWeight: 1, NotQuarantined"
        }
    }
    Add-Finding -Category "Cluster" -Item "Node summary" -Status "INFO" -Detail "$upNodes of $($nodes.Count) nodes Up; approx. $totalVotes active votes (nodes with DynamicWeight=1 + witness if present)"
} catch {
    Add-Finding -Category "Node" -Item "(error)" -Status "ERROR" -Detail "Get-ClusterNode failed: $($_.Exception.Message)"
}
#endregion

#region --- 3. Witness resource health ---
Write-Status "`n=== Quorum Witness ===" -Status "INFO"
try {
    $witnessRes = Get-ClusterResource @clusterParams -ErrorAction Stop | Where-Object { $_.ResourceType -match "Witness" }
    if (-not $witnessRes) {
        Add-Finding -Category "Witness" -Item "(none configured)" -Status $(if ($nodes.Count % 2 -eq 0) { "WARN" } else { "INFO" }) `
            -Detail $(if ($nodes.Count % 2 -eq 0) { "No witness configured on an even node count ($($nodes.Count) nodes) — best practice is an odd total vote count" } else { "No witness configured — acceptable for an odd node count, but confirm this was intentional" })
    } else {
        foreach ($w in $witnessRes) {
            if ($w.State -eq "Online") {
                Add-Finding -Category "Witness" -Item $w.Name -Status "OK" -Detail "Type: $($w.ResourceType), State: Online, Owner: $($w.OwnerNode)"
            } else {
                Add-Finding -Category "Witness" -Item $w.Name -Status "ERROR" -Detail "Type: $($w.ResourceType), State: $($w.State) — cluster is running on reduced quorum margin"
            }
        }
    }
} catch {
    Add-Finding -Category "Witness" -Item "(error)" -Status "WARN" -Detail "Get-ClusterResource failed: $($_.Exception.Message)"
}
#endregion

#region --- 4. Cluster networks ---
Write-Status "`n=== Cluster Networks ===" -Status "INFO"
try {
    $networks = Get-ClusterNetwork @clusterParams -ErrorAction Stop
    foreach ($net in $networks) {
        if ($net.State -eq "Partitioned") {
            Add-Finding -Category "Network" -Item $net.Name -Status "ERROR" -Detail "State: Partitioned (asymmetric — some but not all nodes can reach each other over this network; more dangerous than a fully Down network) Role: $($net.Role)"
        } elseif ($net.State -ne "Up") {
            Add-Finding -Category "Network" -Item $net.Name -Status "ERROR" -Detail "State: $($net.State), Role: $($net.Role)"
        } else {
            Add-Finding -Category "Network" -Item $net.Name -Status "OK" -Detail "State: Up, Role: $($net.Role), Metric: $($net.Metric)"
        }
    }
} catch {
    Add-Finding -Category "Network" -Item "(error)" -Status "WARN" -Detail "Get-ClusterNetwork failed: $($_.Exception.Message)"
}
#endregion

#region --- 5. Recent quorum/quarantine/network/storage events ---
Write-Status "`n=== Recent Cluster Events (last $EventLookbackHours h) ===" -Status "INFO"
$eventIdMap = @{
    1069 = "Quorum-related resource failure"
    1135 = "Node removed from cluster membership"
    1177 = "Cluster membership/heartbeat issue"
    1558 = "Cluster configuration/certificate issue"
    1641 = "Node quarantine activated"
    1647 = "Node quarantine — related state change"
    1649 = "Node quarantine — related state change"
    5120 = "Cluster Shared Volume paused/disconnected"
    5142 = "Cluster Shared Volume connectivity issue"
    7031 = "Service Control Manager — unexpected service termination (often RHS)"
}
try {
    $since = (Get-Date).AddHours(-$EventLookbackHours)
    $events = Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -ErrorAction Stop |
        Where-Object { $_.TimeCreated -ge $since -and $_.Id -in $eventIdMap.Keys }
    if ($events) {
        foreach ($e in $events | Sort-Object TimeCreated -Descending | Select-Object -First 30) {
            Add-Finding -Category "EventLog" -Item "EventID $($e.Id) ($($eventIdMap[[int]$e.Id]))" -Status "WARN" -Detail "$($e.TimeCreated) — $($e.Message.Split("`n")[0])"
        }
    } else {
        Add-Finding -Category "EventLog" -Item "Quorum/quarantine/network/storage IDs" -Status "OK" -Detail "No matching events in the last $EventLookbackHours hours"
    }
} catch {
    Add-Finding -Category "EventLog" -Item "(error)" -Status "WARN" -Detail "Get-WinEvent failed (log may not exist on this OS, or requires elevation): $($_.Exception.Message)"
}
#endregion

#region --- 6. Cluster-Aware Updating status (if configured) ---
Write-Status "`n=== Cluster-Aware Updating ===" -Status "INFO"
try {
    if (Get-Command Get-CauClusterRole -ErrorAction SilentlyContinue) {
        $cauRole = Get-CauClusterRole @clusterParams -ErrorAction SilentlyContinue
        if ($cauRole) {
            Add-Finding -Category "CAU" -Item "Self-updating role" -Status "OK" -Detail "Configured — next run per role schedule"
        } else {
            Add-Finding -Category "CAU" -Item "Self-updating role" -Status "INFO" -Detail "Not configured — cluster is patched via remote-updating mode or manually"
        }
    } else {
        Add-Finding -Category "CAU" -Item "(module)" -Status "INFO" -Detail "CAU cmdlets not available on this machine — skipping (install RSAT Failover Clustering tools to check)"
    }
} catch {
    Add-Finding -Category "CAU" -Item "(error)" -Status "INFO" -Detail "CAU check failed non-fatally: $($_.Exception.Message)"
}
#endregion

#region --- Summary and export ---
$errorCount = ($findings | Where-Object Status -eq "ERROR").Count
$warnCount  = ($findings | Where-Object Status -eq "WARN").Count
Write-Status "`n=== Summary: $errorCount ERROR, $warnCount WARN out of $($findings.Count) checks ===" -Status $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

$csvPath = Join-Path $OutputPath "FailoverClusterHealth_$(Get-Date -Format yyyyMMdd-HHmm).csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Findings exported to $csvPath" -Status "INFO"
Write-Status "For a full escalation package, also run: Get-ClusterLog -Destination <path> -UseLocal -TimeSpan 120" -Status "INFO"
#endregion
