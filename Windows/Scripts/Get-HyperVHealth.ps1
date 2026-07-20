<#
.SYNOPSIS
    Audits a Hyper-V host (standalone or clustered) for common VM,
    Integration Services, checkpoint, cluster, and Replica health issues.

.DESCRIPTION
    Read-only diagnostic script for the HyperV-A.md and HyperV-B.md
    runbooks. Run directly on the Hyper-V host with local Administrator
    rights (Hyper-V Administrators group is sufficient for most checks).

    Covers:
      1. Hyper-V role/VMMS service state
      2. VM inventory, state, and status
      3. Integration Services health (Heartbeat especially)
      4. Checkpoint inventory and orphaned/deep chain detection
      5. Virtual switch inventory
      6. [Clustered only] Cluster node, quorum, and CSV health
      7. [Clustered only] VM cluster resource possible-owner check
      8. Hyper-V Replica health (if configured)
      9. Recent Hyper-V-VMMS / Hyper-V-Worker event log errors

    Does NOT modify any VM, checkpoint, or cluster configuration; does NOT
    perform a live migration test; does NOT evaluate guest-OS-internal
    health once the VM is confirmed Running/Operating normally at the
    virtualization layer.

.PARAMETER CheckpointChainWarnDepth
    Differencing disk chain depth at or above which a WARN finding is
    raised for a VM's checkpoints. Default: 10.

.PARAMETER OutputPath
    Folder to write CSV output to. Default: current directory.

.EXAMPLE
    .\Get-HyperVHealth.ps1
    Runs a standard local audit with default 10-deep checkpoint chain threshold.

.EXAMPLE
    .\Get-HyperVHealth.ps1 -CheckpointChainWarnDepth 5 -OutputPath C:\HyperV-Audit
    Runs an audit flagging checkpoint chains 5+ deep, output to C:\HyperV-Audit.

.NOTES
    Requires: Hyper-V PowerShell module (installed with the Hyper-V role).
    FailoverClusters module (optional) for cluster/CSV/quorum checks —
    auto-skipped if this host isn't clustered or the module is unavailable.
    Run-as: local Administrator or Hyper-V Administrators on the host.
    Safe: read-only, no VM/checkpoint/cluster configuration changes are made.
#>

[CmdletBinding()]
param(
    [int]$CheckpointChainWarnDepth = 10,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$findings = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param([string]$Category, [string]$Flag, [string]$Detail, [string]$Severity = "INFO")
    $findings.Add([PSCustomObject]@{
        Category = $Category
        Flag     = $Flag
        Severity = $Severity
        Detail   = $Detail
    })
}

# ─── Preflight ────────────────────────────────────────────────────────────
Write-Status "Starting Hyper-V host health audit..." "INFO"

$hvFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
if (-not $hvFeature -or $hvFeature.InstallState -ne "Installed") {
    Add-Finding "Preflight" "HYPERV_ROLE_NOT_INSTALLED" "Hyper-V role is not installed on this machine. Run this script directly on the Hyper-V host." "ERROR"
    Write-Status "Hyper-V role not installed — aborting further checks." "ERROR"
    $findings | Export-Csv -Path (Join-Path $OutputPath "HyperVHealth-$stamp.csv") -NoTypeInformation
    return
}
Write-Status "Hyper-V role presence confirmed." "OK"

# ─── 1. VMMS service state ──────────────────────────────────────────────────
Write-Status "Checking VMMS service state..." "INFO"
try {
    $vmms = Get-Service -Name VMMS -ErrorAction Stop
    if ($vmms.Status -ne "Running") {
        Add-Finding "Service" "VMMS_NOT_RUNNING" "Virtual Machine Management Service is in state '$($vmms.Status)'. Host-wide VM management operations will fail, though already-running VMs (independent vmwp.exe processes) are unaffected." "ERROR"
    } else {
        Add-Finding "Service" "VMMS_RUNNING" "VMMS is running." "OK"
    }
} catch {
    Add-Finding "Service" "VMMS_CHECK_FAILED" "Could not query VMMS service: $($_.Exception.Message)" "WARN"
}

# ─── 2. VM inventory, state, and status ─────────────────────────────────────
Write-Status "Inventorying VMs..." "INFO"
$vms = @()
try {
    $vms = Get-VM -ErrorAction Stop
    if (-not $vms -or $vms.Count -eq 0) {
        Add-Finding "VMs" "NO_VMS_FOUND" "No virtual machines found on this host." "INFO"
    } else {
        $vms | Select-Object Name, State, Status, Version, Uptime |
            Export-Csv -Path (Join-Path $OutputPath "VMs-$stamp.csv") -NoTypeInformation

        $unhealthy = $vms | Where-Object { $_.State -eq "Running" -and $_.Status -ne "Operating normally" }
        foreach ($u in $unhealthy) {
            Add-Finding "VMs" "VM_STATUS_DEGRADED" "VM '$($u.Name)' is Running but Status is '$($u.Status)' (not 'Operating normally')." "WARN"
        }
        $off = $vms | Where-Object { $_.State -eq "Off" }
        $critical = $vms | Where-Object { $_.State -eq "Critical" }
        foreach ($c in $critical) {
            Add-Finding "VMs" "VM_STATE_CRITICAL" "VM '$($c.Name)' is in Critical state — usually a missing/inaccessible virtual hard disk or configuration resource." "ERROR"
        }
        Add-Finding "VMs" "VM_COUNT" "$($vms.Count) VM(s) found: $($vms.Count - $off.Count) not Off, $($off.Count) Off, $($critical.Count) Critical." "OK"
    }
} catch {
    Add-Finding "VMs" "VM_QUERY_FAILED" "Could not query VMs: $($_.Exception.Message)" "WARN"
}

# ─── 3. Integration Services health ─────────────────────────────────────────
Write-Status "Checking Integration Services (Heartbeat focus)..." "INFO"
try {
    if ($vms.Count -gt 0) {
        $intSvc = $vms | Get-VMIntegrationService -ErrorAction SilentlyContinue
        $intSvc | Select-Object VMName, Name, Enabled, PrimaryStatusDescription |
            Export-Csv -Path (Join-Path $OutputPath "IntegrationServices-$stamp.csv") -NoTypeInformation

        $badHeartbeat = $intSvc | Where-Object { $_.Name -eq "Heartbeat" -and ($_.Enabled -eq $false -or $_.PrimaryStatusDescription -ne "OK") }
        foreach ($h in $badHeartbeat) {
            Add-Finding "IntegrationServices" "HEARTBEAT_UNHEALTHY" "VM '$($h.VMName)' Heartbeat service: Enabled=$($h.Enabled), Status='$($h.PrimaryStatusDescription)'. Fastest liveness signal for a guest/VMBus-level problem — check host AND guest side." "WARN"
        }
        if (-not $badHeartbeat) {
            Add-Finding "IntegrationServices" "HEARTBEAT_HEALTHY" "All VMs report healthy Heartbeat status." "OK"
        }
    }
} catch {
    Add-Finding "IntegrationServices" "INTEGRATION_SERVICE_CHECK_FAILED" "Could not query Integration Services: $($_.Exception.Message)" "WARN"
}

# ─── 4. Checkpoint inventory and chain depth ────────────────────────────────
Write-Status "Checking checkpoints and differencing disk chains..." "INFO"
try {
    if ($vms.Count -gt 0) {
        $snaps = $vms | Get-VMSnapshot -ErrorAction SilentlyContinue
        if ($snaps) {
            $snaps | Select-Object VMName, Name, CreationTime, SnapshotType |
                Export-Csv -Path (Join-Path $OutputPath "Checkpoints-$stamp.csv") -NoTypeInformation
            $snapCounts = $snaps | Group-Object VMName
            foreach ($g in $snapCounts) {
                if ($g.Count -ge $CheckpointChainWarnDepth) {
                    Add-Finding "Checkpoints" "CHECKPOINT_CHAIN_DEEP" "VM '$($g.Name)' has $($g.Count) checkpoint(s) (threshold: $CheckpointChainWarnDepth). Deep chains grow disk usage and read-path latency; confirm third-party backup software is cleaning up after itself." "WARN"
                }
            }
            Add-Finding "Checkpoints" "CHECKPOINT_COUNT" "$($snaps.Count) checkpoint(s) found across $($snapCounts.Count) VM(s)." "OK"
        } else {
            Add-Finding "Checkpoints" "NO_CHECKPOINTS" "No checkpoints found on any VM." "INFO"
        }

        # Orphan detection: .avhdx files present but not backed by a visible checkpoint
        $diskInfo = $vms | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
            try { Get-VHD -Path $_.Path -ErrorAction Stop } catch { $null }
        } | Where-Object { $_ }
        $diskInfo | Select-Object Path, ParentPath, VhdType |
            Export-Csv -Path (Join-Path $OutputPath "DiskChains-$stamp.csv") -NoTypeInformation
        $avhdxCount = ($diskInfo | Where-Object { $_.Path -like "*.avhdx" }).Count
        $snapCount = if ($snaps) { $snaps.Count } else { 0 }
        if ($avhdxCount -gt $snapCount) {
            Add-Finding "Checkpoints" "POSSIBLE_ORPHANED_AVHDX" "$avhdxCount differencing disk(s) (.avhdx) found on disk vs. $snapCount visible checkpoint(s) — possible orphaned checkpoint files (common when backup software doesn't clean up). Review DiskChains-$stamp.csv manually." "WARN"
        }
    }
} catch {
    Add-Finding "Checkpoints" "CHECKPOINT_CHECK_FAILED" "Could not query checkpoints/disk chains: $($_.Exception.Message)" "WARN"
}

# ─── 5. Virtual switch inventory ────────────────────────────────────────────
Write-Status "Inventorying virtual switches..." "INFO"
try {
    $switches = Get-VMSwitch -ErrorAction SilentlyContinue
    if ($switches) {
        $switches | Select-Object Name, SwitchType, NetAdapterInterfaceDescription |
            Export-Csv -Path (Join-Path $OutputPath "VirtualSwitches-$stamp.csv") -NoTypeInformation
        Add-Finding "Networking" "SWITCH_COUNT" "$($switches.Count) virtual switch(es) found. Remember: switch NAMES must match exactly across all hosts for Live Migration to succeed." "OK"
    } else {
        Add-Finding "Networking" "NO_SWITCHES" "No virtual switches configured on this host." "WARN"
    }
} catch {
    Add-Finding "Networking" "SWITCH_CHECK_FAILED" "Could not query virtual switches: $($_.Exception.Message)" "WARN"
}

# ─── 6/7. Cluster, quorum, CSV, and VM resource ownership (clustered only) ──
Write-Status "Checking for Failover Clustering (skips cleanly if standalone)..." "INFO"
if (Get-Command Get-Cluster -ErrorAction SilentlyContinue) {
    try {
        $cluster = Get-Cluster -ErrorAction Stop
        Add-Finding "Cluster" "CLUSTER_DETECTED" "Host is part of cluster '$($cluster.Name)', QuorumType: $($cluster.QuorumType)." "INFO"

        $nodes = Get-ClusterNode -ErrorAction SilentlyContinue
        $nodes | Export-Csv -Path (Join-Path $OutputPath "ClusterNodes-$stamp.csv") -NoTypeInformation
        $downNodes = $nodes | Where-Object { $_.State -ne "Up" }
        foreach ($n in $downNodes) {
            Add-Finding "Cluster" "NODE_DOWN" "Cluster node '$($n.Name)' is in state '$($n.State)'. If multiple unrelated VMs went offline simultaneously, check quorum before any per-VM diagnosis." "ERROR"
        }
        if (-not $downNodes) {
            Add-Finding "Cluster" "ALL_NODES_UP" "All $($nodes.Count) cluster node(s) are Up." "OK"
        }

        $csvs = Get-ClusterSharedVolume -ErrorAction SilentlyContinue
        if ($csvs) {
            $csvs | Select-Object Name, State, Node | Export-Csv -Path (Join-Path $OutputPath "CSVs-$stamp.csv") -NoTypeInformation
            $badCsv = $csvs | Where-Object { $_.State -ne "Online" }
            foreach ($c in $badCsv) {
                Add-Finding "Cluster" "CSV_NOT_ONLINE" "CSV '$($c.Name)' is in state '$($c.State)' (not Online)." "ERROR"
            }
            if (-not $badCsv) {
                Add-Finding "Cluster" "CSV_ALL_ONLINE" "All $($csvs.Count) CSV(s) are Online." "OK"
            }
        }

        $vmResources = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -eq "Virtual Machine" }
        if ($vmResources) {
            $ownerReport = foreach ($r in $vmResources) {
                $owners = $r | Get-ClusterOwnerNode -ErrorAction SilentlyContinue
                [PSCustomObject]@{
                    ResourceName    = $r.Name
                    State           = $r.State
                    OwnerNode       = $r.OwnerNode
                    PossibleOwners  = ($owners.OwnerNodes -join ";")
                    PossibleOwnerCount = $owners.OwnerNodes.Count
                }
            }
            $ownerReport | Export-Csv -Path (Join-Path $OutputPath "VMClusterResources-$stamp.csv") -NoTypeInformation
            $incompleteOwners = $ownerReport | Where-Object { $_.PossibleOwnerCount -lt $nodes.Count }
            foreach ($i in $incompleteOwners) {
                Add-Finding "Cluster" "VM_RESOURCE_MISSING_POSSIBLE_OWNER" "'$($i.ResourceName)' lists only $($i.PossibleOwnerCount) of $($nodes.Count) node(s) as possible owners — a common silent cause of Live Migration Event ID 21502 (0x80071398) when a node was added to the cluster after this VM resource was created." "WARN"
            }
        }
    } catch {
        Add-Finding "Cluster" "CLUSTER_CHECK_FAILED" "Could not query cluster state: $($_.Exception.Message)" "WARN"
    }
} else {
    Add-Finding "Cluster" "NOT_CLUSTERED" "FailoverClusters module not available or host isn't clustered — standalone host checks only." "INFO"
}

# ─── 8. Hyper-V Replica health ──────────────────────────────────────────────
Write-Status "Checking Hyper-V Replica configuration..." "INFO"
try {
    $replicas = Get-VMReplication -ErrorAction SilentlyContinue
    if ($replicas -and $replicas.Count -gt 0) {
        $replicas | Select-Object VMName, State, Health, PrimaryServer, ReplicaServer |
            Export-Csv -Path (Join-Path $OutputPath "Replication-$stamp.csv") -NoTypeInformation
        $badHealth = $replicas | Where-Object { $_.Health -ne "Normal" }
        foreach ($b in $badHealth) {
            Add-Finding "Replica" "REPLICATION_UNHEALTHY" "VM '$($b.VMName)' replication Health: '$($b.Health)', State: '$($b.State)'. Check pending change volume (Measure-VMReplication) and the primary-side .hrl file size for growth — HRL growth is the leading indicator of a replica silently falling behind." "WARN"
        }
        if (-not $badHealth) {
            Add-Finding "Replica" "REPLICATION_HEALTHY" "$($replicas.Count) replicated VM(s), all reporting Health: Normal." "OK"
        }
    } else {
        Add-Finding "Replica" "NO_REPLICATION_CONFIGURED" "No Hyper-V Replica relationships configured on this host." "INFO"
    }
} catch {
    Add-Finding "Replica" "REPLICATION_CHECK_FAILED" "Could not query Hyper-V Replica state (module may be absent or Replica not enabled): $($_.Exception.Message)" "INFO"
}

# ─── 9. Recent Hyper-V event log errors ─────────────────────────────────────
Write-Status "Scanning Hyper-V-VMMS and Hyper-V-Worker logs (last 7 days)..." "INFO"
try {
    $since = (Get-Date).AddDays(-7)
    $vmmsEvents = Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-Hyper-V-VMMS-Admin"; Level = 1,2,3; StartTime = $since } -ErrorAction SilentlyContinue
    $workerEvents = Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-Hyper-V-Worker-Admin"; Level = 1,2,3; StartTime = $since } -ErrorAction SilentlyContinue

    if ($vmmsEvents) {
        $vmmsEvents | Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv -Path (Join-Path $OutputPath "VMMSEvents-$stamp.csv") -NoTypeInformation
        Add-Finding "Events" "VMMS_ERRORS_FOUND" "$($vmmsEvents.Count) Error/Warning/Critical Hyper-V-VMMS event(s) in the last 7 days." "WARN"
    }
    if ($workerEvents) {
        $workerEvents | Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv -Path (Join-Path $OutputPath "WorkerEvents-$stamp.csv") -NoTypeInformation
        Add-Finding "Events" "WORKER_ERRORS_FOUND" "$($workerEvents.Count) Error/Warning/Critical Hyper-V-Worker event(s) in the last 7 days." "WARN"
    }
    if (-not $vmmsEvents -and -not $workerEvents) {
        Add-Finding "Events" "NO_RECENT_EVENT_ERRORS" "No Error/Warning/Critical Hyper-V-VMMS/Worker events in the last 7 days." "OK"
    }

    # CSV 5120 events — distinguish benign auto-pause-only noise from real signal
    $csv5120 = Get-WinEvent -FilterXPath "*[System[(EventID=5120)]]" -LogName System -MaxEvents 50 -ErrorAction SilentlyContinue
    if ($csv5120) {
        $nonBenign = $csv5120 | Where-Object { $_.Message -notmatch "STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR|c0130021" }
        if ($nonBenign) {
            Add-Finding "Events" "CSV_5120_GENUINE" "$($nonBenign.Count) Event ID 5120 entr(y/ies) with a status code OTHER than the benign STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR — treat as a genuine storage/network interruption signal, not noise." "WARN"
        } else {
            Add-Finding "Events" "CSV_5120_BENIGN_ONLY" "$($csv5120.Count) Event ID 5120 entr(y/ies) found, all STATUS_CLUSTER_CSV_AUTO_PAUSE_ERROR (known benign pattern)." "INFO"
        }
    }
} catch {
    Add-Finding "Events" "EVENT_LOG_QUERY_FAILED" "Could not query Hyper-V event logs: $($_.Exception.Message)" "WARN"
}

# ─── Report ─────────────────────────────────────────────────────────────
$reportPath = Join-Path $OutputPath "HyperVHealth-$stamp.csv"
$findings | Export-Csv -Path $reportPath -NoTypeInformation

Write-Status "Audit complete. $($findings.Count) finding(s) recorded." "INFO"
$errorCount = ($findings | Where-Object { $_.Severity -eq "ERROR" }).Count
$warnCount  = ($findings | Where-Object { $_.Severity -eq "WARN" }).Count
Write-Status "$errorCount error-level, $warnCount warning-level finding(s)." $(if ($errorCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Full report: $reportPath" "INFO"

$findings | Format-Table -AutoSize
